import Foundation

public struct DebugChaosConfiguration: Equatable, Sendable {
    public let watchUnreachable: Bool
    public let staleHeartRate: Bool
    public let staleGPS: Bool
    public let telemetryDropRate: Double
    public let reorderTelemetry: Bool
    public let seed: UInt64

    public static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        #if DEBUG
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        return .init(watchUnreachable: arguments.contains("-SafeRunWCUnreachable"), staleHeartRate: arguments.contains("-SafeRunStaleHR"), staleGPS: arguments.contains("-SafeRunStaleGPS"), telemetryDropRate: arguments.contains("-SafeRunDropTelemetry10") ? 0.1 : 0, reorderTelemetry: arguments.contains("-SafeRunReorderPackets"), seed: UInt64(value(after: "-SafeRunChaosSeed") ?? "0") ?? 0)
        #else
        return .disabled
        #endif
    }
    public static let disabled = Self(watchUnreachable: false, staleHeartRate: false, staleGPS: false, telemetryDropRate: 0, reorderTelemetry: false, seed: 0)
}

@MainActor
public final class DebugChaosController {
    public let configuration: DebugChaosConfiguration
    private var state: UInt64
    public init(configuration: DebugChaosConfiguration = .current()) { self.configuration = configuration; state = configuration.seed == 0 ? 0x9E3779B97F4A7C15 : configuration.seed }
    public func shouldDropTelemetry() -> Bool {
        #if DEBUG
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state % 10_000) / 10_000 < configuration.telemetryDropRate
        #else
        return false
        #endif
    }
}
