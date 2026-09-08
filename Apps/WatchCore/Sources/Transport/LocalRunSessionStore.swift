import Foundation
import SafeRunDomain

public struct LocalRunSessionSnapshot: Codable, Equatable, Sendable {
    public var sessionID: String?
    public var lastIssued: Int

    public init(sessionID: String? = nil, lastIssued: Int = 0) {
        self.sessionID = sessionID
        self.lastIssued = lastIssued
    }
}

public actor LocalRunSessionStore {
    private let fileURL: URL
    private var state: LocalRunSessionSnapshot

    public init(fileURL: URL) {
        self.fileURL = fileURL
        state = (try? Data(contentsOf: fileURL))
            .flatMap { try? SafeRunJSON.makeDecoder().decode(LocalRunSessionSnapshot.self, from: $0) }
            ?? LocalRunSessionSnapshot()
    }

    public func begin() throws -> LocalRunSessionSnapshot {
        if state.sessionID == nil {
            state = LocalRunSessionSnapshot(sessionID: UUID().uuidString, lastIssued: 0)
            try persist()
        }
        return state
    }

    public func issueNext() throws -> (sessionID: String, sequence: Int) {
        if state.sessionID == nil { _ = try begin() }
        guard let sessionID = state.sessionID, state.lastIssued < Int.max else {
            throw LocalRunSessionError.invalidState
        }
        let oldState = state
        state.lastIssued += 1
        do { try persist() } catch { state = oldState; throw error }
        return (sessionID, state.lastIssued)
    }

    public func end() throws {
        let oldState = state
        state.sessionID = nil
        do { try persist() } catch { state = oldState; throw error }
    }

    public func snapshot() -> LocalRunSessionSnapshot { state }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SafeRunJSON.makeEncoder().encode(state).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
    }
}

public enum LocalRunSessionError: Error { case invalidState }
