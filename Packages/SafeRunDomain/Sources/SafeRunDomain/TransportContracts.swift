import Foundation

public enum PacketPriority: Int, Codable, CaseIterable, Comparable, Equatable, Sendable {
    case critical = 0
    case lifecycle = 1
    case stateSync = 2
    case telemetry = 3

    public static func < (lhs: PacketPriority, rhs: PacketPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TransportAcknowledgementStatus: String, Codable, Equatable, Sendable {
    case queued
    case duplicate
    case rejected
}

public struct TransportAcknowledgement: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packetID: UUID
    public let status: TransportAcknowledgementStatus
    public let errorCode: String?

    public init(
        packetID: UUID,
        status: TransportAcknowledgementStatus,
        errorCode: String? = nil
    ) {
        self.schemaVersion = SafeRunContract.schemaVersion
        self.packetID = packetID
        self.status = status
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case packetID = "packet_id"
        case status
        case errorCode = "error_code"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == SafeRunContract.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported acknowledgement schema version."
            )
        }
        schemaVersion = version
        packetID = try container.decode(UUID.self, forKey: .packetID)
        status = try container.decode(TransportAcknowledgementStatus.self, forKey: .status)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
    }
}

public struct TransportPacket: Codable, Equatable, Sendable, Identifiable {
    public let packetID: UUID
    public let sessionID: String
    public let sequence: Int
    public let kind: EnvelopeKind
    public let priority: PacketPriority
    public let watchTimestamp: Date
    public let envelopeData: Data

    public var id: UUID { packetID }

    public init(
        packetID: UUID,
        sessionID: String,
        sequence: Int,
        kind: EnvelopeKind,
        priority: PacketPriority,
        watchTimestamp: Date,
        envelopeData: Data
    ) {
        self.packetID = packetID
        self.sessionID = sessionID
        self.sequence = sequence
        self.kind = kind
        self.priority = priority
        self.watchTimestamp = watchTimestamp
        self.envelopeData = envelopeData
    }

    public static func decodeEnvelope(_ data: Data) throws -> TransportPacket {
        let decoder = SafeRunJSON.makeDecoder()
        let header = try decoder.decode(EnvelopeHeader.self, from: data)
        guard header.schemaVersion == SafeRunContract.schemaVersion, header.sequence >= 1 else {
            throw TransportContractError.invalidEnvelope
        }

        switch header.kind {
        case .telemetry:
            let envelope = try decoder.decode(TelemetryEnvelope.self, from: data)
            return TransportPacket(
                packetID: envelope.packetID,
                sessionID: envelope.sessionID,
                sequence: envelope.sequence,
                kind: envelope.kind,
                priority: .telemetry,
                watchTimestamp: envelope.watchTimestamp,
                envelopeData: data
            )
        case .event:
            let envelope = try decoder.decode(EventEnvelope.self, from: data)
            return TransportPacket(
                packetID: envelope.packetID,
                sessionID: envelope.sessionID,
                sequence: envelope.sequence,
                kind: envelope.kind,
                priority: priority(for: envelope.payload),
                watchTimestamp: envelope.watchTimestamp,
                envelopeData: data
            )
        }
    }

    private static func priority(for payload: EventPayload) -> PacketPriority {
        if payload.severity == .critical { return .critical }
        switch payload.eventType {
        case .stateSync:
            return .stateSync
        case .sessionStarted, .sessionPaused, .sessionResumed, .sessionEnded:
            return .lifecycle
        default:
            return .lifecycle
        }
    }
}

public enum TransportContractError: Error, Equatable, Sendable {
    case invalidEnvelope
}

private struct EnvelopeHeader: Decodable {
    let schemaVersion: Int
    let sequence: Int
    let kind: EnvelopeKind

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence = "seq"
        case kind
    }
}
