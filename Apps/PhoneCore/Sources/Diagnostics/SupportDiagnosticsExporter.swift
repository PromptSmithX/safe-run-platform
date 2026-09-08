import Foundation

public struct SupportDiagnosticSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let queueDepth: Int
    public let retryCount: Int
    public let errorCodes: [String]

    public init(schemaVersion: Int = 1, generatedAt: Date = Date(), appVersion: String, queueDepth: Int, retryCount: Int, errorCodes: [String]) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.appVersion = appVersion; self.queueDepth = queueDepth
        self.retryCount = retryCount; self.errorCodes = errorCodes
    }
}

public enum SupportDiagnosticsExporter {
    public static func create(_ snapshot: SupportDiagnosticSnapshot) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("safe-run-support-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
