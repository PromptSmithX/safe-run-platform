import Combine
import Foundation
import SafeRunDomain
import WatchConnectivity

public struct PhoneTransportDiagnostics: Equatable, Sendable {
    public var activationState = "notActivated"
    public var isPaired = false
    public var isWatchAppInstalled = false
    public var isReachable = false
    public var queueDepth = 0
    public var queueCounts: [PacketPriority: Int] = [:]
    public var lastPacketID: UUID?
    public var lastError: String?

    public init() {}
}

@MainActor
public final class PhoneWatchBridge: NSObject, ObservableObject {
    @Published public private(set) var diagnostics = PhoneTransportDiagnostics()

    private let session: WCSession
    private let queue: SQLiteGatewayQueue?

    public init(queue: SQLiteGatewayQueue?, session: WCSession = .default) {
        self.queue = queue
        self.session = session
        super.init()
        session.delegate = self
    }

    public func activate() {
        session.activate()
        refreshConnection()
        Task { await refreshQueue() }
    }

    public func processMessageData(_ data: Data) async -> Data {
        let acknowledgement = await accept(data)
        return (try? SafeRunJSON.makeEncoder().encode(acknowledgement)) ?? Data()
    }

    private func accept(_ data: Data) async -> TransportAcknowledgement {
        let packet: TransportPacket
        do {
            packet = try TransportPacket.decodeEnvelope(data)
        } catch {
            diagnostics.lastError = "invalid_envelope"
            return TransportAcknowledgement(
                packetID: Self.bestEffortPacketID(from: data),
                status: .rejected,
                errorCode: "invalid_envelope"
            )
        }
        guard let queue else {
            diagnostics.lastError = "storage_unavailable"
            return TransportAcknowledgement(
                packetID: packet.packetID,
                status: .rejected,
                errorCode: "storage_unavailable"
            )
        }
        do {
            let result = try await queue.accept(packet)
            await refreshQueue()
            diagnostics.lastPacketID = packet.packetID
            diagnostics.lastError = nil
            return TransportAcknowledgement(
                packetID: packet.packetID,
                status: result == .inserted ? .queued : .duplicate
            )
        } catch {
            diagnostics.lastError = error.localizedDescription
            return TransportAcknowledgement(
                packetID: packet.packetID,
                status: .rejected,
                errorCode: "storage_unavailable"
            )
        }
    }

    private func refreshQueue() async {
        guard let queue, let snapshot = try? await queue.snapshot() else { return }
        diagnostics.queueDepth = snapshot.totalCount
        diagnostics.queueCounts = snapshot.counts
        diagnostics.lastPacketID = snapshot.lastPacketID ?? diagnostics.lastPacketID
    }

    private func refreshConnection() {
        diagnostics.activationState = String(describing: session.activationState)
        diagnostics.isPaired = session.isPaired
        diagnostics.isWatchAppInstalled = session.isWatchAppInstalled
        diagnostics.isReachable = session.isReachable
    }

    private static func bestEffortPacketID(from data: Data) -> UUID {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["packet_id"] as? String,
              let id = UUID(uuidString: raw) else {
            return UUID()
        }
        return id
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.refreshConnection()
            if let error { self?.diagnostics.lastError = error.localizedDescription }
        }
    }

    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshConnection() }
    }

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor [weak self] in self?.refreshConnection() }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshConnection() }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            replyHandler(await processMessageData(messageData))
        }
    }
}
