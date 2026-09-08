import Foundation
import XCTest
@testable import SafeRunWatchCore

final class LocalRunSessionStoreTests: XCTestCase {
    func testSessionAndSequenceResumeAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        let firstStore = LocalRunSessionStore(fileURL: url)
        let first = try await firstStore.issueNext()
        let secondStore = LocalRunSessionStore(fileURL: url)
        let second = try await secondStore.issueNext()

        XCTAssertEqual(first.sessionID, second.sessionID)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
    }
}
