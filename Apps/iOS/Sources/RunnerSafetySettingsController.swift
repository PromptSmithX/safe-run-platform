import Combine
import Foundation
import SafeRunDomain
import SafeRunPhoneCore

@MainActor
final class RunnerSafetySettingsController: ObservableObject {
    @Published var enabled = false
    @Published var thresholdText = ""
    @Published private(set) var status = "Not configured"
    private let store: RunnerSafetyConfigurationStore
    private weak var bridge: PhoneWatchBridge?

    init(store: RunnerSafetyConfigurationStore, bridge: PhoneWatchBridge) {
        self.store = store; self.bridge = bridge
        Task { await load() }
    }

    func load() async {
        guard let envelope = await store.load() else { return }
        enabled = envelope.config.highHRThresholdBPM != nil
        thresholdText = envelope.config.highHRThresholdBPM.map { String(Int($0)) } ?? ""
        status = "Saved revision \(envelope.revision)"
        try? bridge?.sendSafetyConfiguration(envelope)
    }

    func save() async {
        let threshold = Double(thresholdText)
        guard !enabled || threshold.map({ (40...240).contains($0) }) == true else { status = "Enter 40–240 BPM"; return }
        do {
            var config = RunnerSafetyConfig(); config.highHRThresholdBPM = enabled ? threshold : nil
            let envelope = try await store.save(config: config)
            try bridge?.sendSafetyConfiguration(envelope)
            status = bridge?.diagnostics.lastConfigurationRevision == envelope.revision
                ? "Sent revision \(envelope.revision) to Watch"
                : "Saved revision \(envelope.revision); Watch sync pending"
        } catch { status = "Saved locally; Watch sync pending" }
    }
}
