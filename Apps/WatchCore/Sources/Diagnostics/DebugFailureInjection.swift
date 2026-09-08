import Foundation

public struct DebugChaosConfiguration: Equatable, Sendable {
    public let watchUnreachable: Bool
    public let staleHeartRate: Bool
    public let staleGPS: Bool
    public let telemetryDropRate: Double
    public let reorderPackets: Bool
    public let seed: UInt64

    #if DEBUG
    public static func launchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        return .init(watchUnreachable: arguments.contains("-SafeRunWCUnreachable"), staleHeartRate: arguments.contains("-SafeRunStaleHR"), staleGPS: arguments.contains("-SafeRunStaleGPS"), telemetryDropRate: arguments.contains("-SafeRunDropTelemetry10") ? 0.1 : 0, reorderPackets: arguments.contains("-SafeRunReorderPackets"), seed: UInt64(value(after: "-SafeRunChaosSeed") ?? "0") ?? 0)
    }
    #else
    public static let launchArguments = Self(watchUnreachable: false, staleHeartRate: false, staleGPS: false, telemetryDropRate: 0, reorderPackets: false, seed: 0)
    #endif
}
