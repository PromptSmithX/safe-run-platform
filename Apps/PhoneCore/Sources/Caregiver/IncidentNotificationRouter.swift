import Foundation

public struct IncidentNotificationRouter: Sendable {
    private var lastAcceptedKey: String?

    public init() {}

    public mutating func accept(userInfo: [String: String]) -> UUID? {
        guard userInfo["type"] == "incident",
              let raw = userInfo["incident_id"],
              let id = UUID(uuidString: raw) else {
            return nil
        }
        let key = "\(id.uuidString)|\(userInfo["incident_status"] ?? "unknown")"
        guard key != lastAcceptedKey else { return nil }
        lastAcceptedKey = key
        return id
    }
}
