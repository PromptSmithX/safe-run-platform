import Foundation
import XCTest
@testable import SafeRunPhoneCore

final class SupportDiagnosticsExporterTests: XCTestCase {
    func testExportContainsOnlyRedactedOperationalFieldsAndCanBeRemoved() throws {
        let url = try SupportDiagnosticsExporter.create(.init(appVersion: "1", queueDepth: 3, retryCount: 2, errorCodes: ["OFFLINE"]))
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for forbidden in ["heart_rate", "latitude", "longitude", "phone", "fcm_token", "ingest_token", "payload_blob"] { XCTAssertFalse(text.contains(forbidden)) }
        SupportDiagnosticsExporter.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
