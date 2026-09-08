import Combine
import Foundation
import SafeRunDomain
import WatchConnectivity

public struct WatchTransportDiagnostics: Equatable, Sendable {
    public var activationState: String
    public var isReachable: Bool
    public var queueDepth: Int
    public var queueCounts: [PacketPriority: Int]
    public var lastAcknowledgedPacketID: UUID?
    public var lastError: String?
    public var lastConfigurationRevision: Int?

    public init(
        activationState: String = "notActivated",
        isReachable: Bool = false,
        queueDepth: Int = 0,
        queueCounts: [PacketPriority: Int] = [:],
        lastAcknowledgedPacketID: UUID? = nil,
        lastError: String? = nil
    ) {
        self.activationState = activationState
        self.isReachable = isReachable
        self.queueDepth = queueDepth
        self.queueCounts = queueCounts
        self.lastAcknowledgedPacketID = lastAcknowledgedPacketID
        self.lastError = lastError
        self.lastConfigurationRevision = nil
    }
}

@MainActor
public protocol WatchTransporting: AnyObject {
    var diagnostics: WatchTransportDiagnostics { get }
    func activate()
    func outboxDidChange() async
}

@MainActor
public protocol WatchMessageSession: AnyObject {
    var activationState: WCSessionActivationState { get }
    var isReachable: Bool { get }
    func activate(delegate: WCSessionDelegate)
    func sendMessageData(
        _ data: Data,
        replyHandler: @escaping (Data) -> Void,
        errorHandler: @escaping (Error) -> Void
    )
}

@MainActor
public final class SystemWatchMessageSession: WatchMessageSession {
    private let session: WCSession

    public init(session: WCSession = .default) { self.session = session }
    public var activationState: WCSessionActivationState { session.activationState }
    public var isReachable: Bool { session.isReachable }
    public func activate(delegate: WCSessionDelegate) {
        session.delegate = delegate
        session.activate()
    }
    public func sendMessageData(
        _ data: Data,
        replyHandler: @escaping (Data) -> Void,
        errorHandler: @escaping (Error) -> Void
    ) {
        session.sendMessageData(data, replyHandler: replyHandler, errorHandler: errorHandler)
    }
}

@MainActor
public final class WatchConnectivityTransport: NSObject, ObservableObject, WatchTransporting {
    @Published public private(set) var diagnostics = WatchTransportDiagnostics()
    public var onSafetyConfiguration: ((RunnerSafetyConfigurationEnvelope) -> Void)?

    private let session: any WatchMessageSession
    private let persistence: WatchRunPersistence
    private let acknowledgementTimeout: TimeInterval
    private let configurationStore: WatchSafetyConfigStore?
    private let chaos: DebugChaosConfiguration
    private var inFlightPacketID: UUID?
    private var timeoutTask: Task<Void, Never>?

    public init(
        persistence: WatchRunPersistence,
        session: any WatchMessageSession = SystemWatchMessageSession(),
        acknowledgementTimeout: TimeInterval = 15,
        configurationStore: WatchSafetyConfigStore? = nil,
        chaos: DebugChaosConfiguration = .current()
    ) {
        self.persistence = persistence
        self.session = session
        self.acknowledgementTimeout = acknowledgementTimeout
        self.configurationStore = configurationStore
        self.chaos = chaos
        super.init()
    }

    public func activate() {
        session.activate(delegate: self)
        refreshConnectionDiagnostics()
        Task { await refreshQueueAndDrain() }
    }

    public func outboxDidChange() async {
        await refreshQueueAndDrain()
    }

    private func refreshQueueAndDrain() async {
        let snapshot = await persistence.snapshot()
        diagnostics.queueDepth = snapshot.totalCount
        diagnostics.queueCounts = snapshot.counts
        if let error = snapshot.storageError { diagnostics.lastError = error }
        guard inFlightPacketID == nil,
              session.activationState == .activated,
              session.isReachable, !chaos.watchUnreachable,
              let packet = await persistence.nextPacket(reorderTelemetry: chaos.reorderTelemetry) else { return }
        send(packet)
    }

    private func send(_ packet: TransportPacket) {
        inFlightPacketID = packet.packetID
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(acknowledgementTimeout * 1_000_000_000))
            guard !Task.isCancelled, inFlightPacketID == packet.packetID else { return }
            failInFlight("ack_timeout")
        }

        session.sendMessageData(packet.envelopeData) { [weak self] reply in
            Task { @MainActor in await self?.handleReply(reply, expected: packet.packetID) }
        } errorHandler: { [weak self] error in
            Task { @MainActor in self?.failInFlight(error.localizedDescription) }
        }
    }

    private func handleReply(_ data: Data, expected packetID: UUID) async {
        guard inFlightPacketID == packetID else { return }
        do {
            let acknowledgement = try SafeRunJSON.makeDecoder().decode(
                TransportAcknowledgement.self,
                from: data
            )
            guard acknowledgement.packetID == packetID,
                  acknowledgement.status == .queued || acknowledgement.status == .duplicate else {
                failInFlight(acknowledgement.errorCode ?? "invalid_acknowledgement")
                return
            }
            try await persistence.acknowledge(packetID: packetID)
            timeoutTask?.cancel()
            inFlightPacketID = nil
            diagnostics.lastAcknowledgedPacketID = packetID
            diagnostics.lastError = nil
            await refreshQueueAndDrain()
        } catch {
            failInFlight(error.localizedDescription)
        }
    }

    private func failInFlight(_ message: String) {
        timeoutTask?.cancel()
        inFlightPacketID = nil
        diagnostics.lastError = message
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshQueueAndDrain()
        }
    }

    private func refreshConnectionDiagnostics() {
        diagnostics.activationState = String(describing: session.activationState)
        diagnostics.isReachable = session.isReachable && !chaos.watchUnreachable
    }
}

extension WatchConnectivityTransport: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["safe_run_configuration"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self, let store = self.configurationStore else { return }
            do {
                let envelope = try SafeRunJSON.makeDecoder().decode(RunnerSafetyConfigurationEnvelope.self, from: data)
                try await store.save(envelope)
                self.diagnostics.lastConfigurationRevision = envelope.revision
                self.onSafetyConfiguration?(envelope)
                self.diagnostics.lastError = nil
            } catch { self.diagnostics.lastError = "invalid_safety_configuration" }
        }
    }
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.refreshConnectionDiagnostics()
            if let error { self?.diagnostics.lastError = error.localizedDescription }
            await self?.refreshQueueAndDrain()
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshConnectionDiagnostics()
            await self?.refreshQueueAndDrain()
        }
    }
}
