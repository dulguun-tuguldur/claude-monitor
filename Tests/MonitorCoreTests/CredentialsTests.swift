// ABOUTME: Tests credential JSON parsing, expiry logic with leeway, and
// ABOUTME: field-preserving token write-back JSON generation.
import XCTest
@testable import MonitorCore

final class CredentialsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
    }

    func testParseValid() throws {
        let c = try Credentials.parse(fixture("credentials-valid"))
        XCTAssertEqual(c.accessToken, "sk-ant-oat01-FAKEFAKEFAKE")
        XCTAssertEqual(c.refreshToken, "sk-ant-ort01-FAKEFAKEFAKE")
        XCTAssertFalse(c.isExpired(now: Date()))
    }

    func testExpiredAndLeeway() throws {
        let c = try Credentials.parse(fixture("credentials-expired"))
        XCTAssertTrue(c.isExpired(now: Date()))
        // fresh token but within 5-minute leeway window counts as expired
        let edge = try Credentials.parse(fixture("credentials-valid"))
        XCTAssertTrue(edge.isExpired(now: edge.expiresAt.addingTimeInterval(-60)))
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try Credentials.parse(Data("{}".utf8)))
    }

    func testWriteBackPreservesUnknownFields() throws {
        let c = try Credentials.parse(fixture("credentials-valid"))
        let newExpiry = Date(timeIntervalSince1970: 2_000_000_000)
        let data = try c.updatedJSON(accessToken: "A2", refreshToken: "R2", expiresAt: newExpiry)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let oauth = obj["claudeAiOauth"] as! [String: Any]
        XCTAssertEqual(oauth["accessToken"] as? String, "A2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "R2")
        XCTAssertEqual(oauth["expiresAt"] as? Int, 2_000_000_000_000)
        XCTAssertEqual(oauth["unknownField"] as? String, "must-survive-writeback")
        XCTAssertEqual((oauth["scopes"] as? [String])?.count, 2)
    }
}
