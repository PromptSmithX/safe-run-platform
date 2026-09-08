import Foundation
import SafeRunDomain

public actor RunnerSafetyConfigurationStore {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() -> RunnerSafetyConfigurationEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? SafeRunJSON.makeDecoder().decode(RunnerSafetyConfigurationEnvelope.self, from: data)
    }
    public func save(config: RunnerSafetyConfig, at date: Date = Date()) throws -> RunnerSafetyConfigurationEnvelope {
        let revision = (load()?.revision ?? 0) + 1
        let envelope = RunnerSafetyConfigurationEnvelope(revision: revision, updatedAt: date, config: config)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SafeRunJSON.makeEncoder().encode(envelope).write(to: fileURL, options: .atomic)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedURL = fileURL; try? protectedURL.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
        return envelope
    }
}
