import Foundation
import SafeRunDomain

public actor WatchSafetyConfigStore {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() -> RunnerSafetyConfigurationEnvelope? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? SafeRunJSON.makeDecoder().decode(RunnerSafetyConfigurationEnvelope.self, from: data)
    }
    public func save(_ envelope: RunnerSafetyConfigurationEnvelope) throws {
        guard envelope.schemaVersion == 1, envelope.revision >= 1,
              envelope.config.highHRThresholdBPM.map({ (40...240).contains($0) }) ?? true else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try SafeRunJSON.makeEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var protectedURL = fileURL; try? protectedURL.setResourceValues(values)
        #if os(watchOS) || os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL.path)
        #endif
    }
}
