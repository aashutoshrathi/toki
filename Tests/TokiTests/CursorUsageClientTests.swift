import Foundation
import XCTest
@testable import Toki

final class CursorUsageClientTests: XCTestCase {
    func testJWTSubjectStripsProviderPrefix() {
        let payload = Data(#"{"sub":"auth0|user_ABC"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CursorAuth.jwtSubject("h.\(payload).s"), "user_ABC")
        XCTAssertNil(CursorAuth.jwtSubject("not-a-jwt"))
    }

    func testPrefersReadableDesktopSignInAndFallsBackToCurrentCLIFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        let db = storage.appendingPathComponent("state.vscdb").path

        let encrypted = (Data("v10".utf8) + Data(repeating: 0, count: 16)).base64EncodedString()
        _ = try Shell.require("/usr/bin/sqlite3", [db, """
            CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'cursor-safe-storage:v1:\(encrypted)');
            """], failureMessage: "Could not create the encrypted Cursor sign-in fixture")
        guard case .missing = CursorAuth.read(home: home.path) else {
            return XCTFail("Encrypted sign-ins should fall back to local activity")
        }

        let cliDirectory = home.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        let cliFile = cliDirectory.appendingPathComponent("auth.json")
        func writeCLISignIn(expiry: Int) throws {
            let payload = Data(#"{"sub":"auth0|user_CLI","exp":\#(expiry)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let session = try JSONEncoder().encode(["accessToken": "h.\(payload).s"])
            try SecureStore.write(data: session, to: cliFile)
        }
        try writeCLISignIn(expiry: 1)
        guard case .missing = CursorAuth.read(home: home.path) else {
            return XCTFail("An expired CLI session should fall back to local activity")
        }

        try writeCLISignIn(expiry: Int(Date().timeIntervalSince1970) + 3600)
        guard case .connected(let cliCredentials) = CursorAuth.read(home: home.path) else {
            return XCTFail("An existing CLI session file should connect without a readable desktop sign-in")
        }
        XCTAssertEqual(cliCredentials.userId, "user_CLI")

        let payload = Data(#"{"sub":"auth0|user_ABC"}"#.utf8).base64EncodedString()
        let token = "h.\(payload).s"
        _ = try Shell.require("/usr/bin/sqlite3", [db, """
            UPDATE ItemTable SET value = '\(token)' WHERE key = 'cursorAuth/accessToken';
            """], failureMessage: "Could not create the plaintext Cursor sign-in fixture")
        guard case .connected(let credentials) = CursorAuth.read(home: home.path) else {
            return XCTFail("Plaintext sign-ins should still connect")
        }
        XCTAssertEqual(credentials.userId, "user_ABC")
    }

    func testParseAggregatedCoercesStringTokensAndNumberCents() {
        // Real shape: token totals arrive as strings, cost as a number.
        let object: [String: Any] = [
            "totalInputTokens": "218140",
            "totalOutputTokens": "58001",
            "totalCacheReadTokens": "6002381",
            "totalCostCents": 44.5428
        ]
        let usage = CursorUsageClient.parseAggregated(object)
        XCTAssertEqual(usage.inputTokens, 218140)
        XCTAssertEqual(usage.outputTokens, 58001)
        XCTAssertEqual(usage.spentCents, 44.5428, accuracy: 0.0001)
    }

    func testParseHardLimitAndCycle() {
        XCTAssertEqual(CursorUsageClient.parseHardLimit(["hardLimit": 200]), 200)
        XCTAssertNil(CursorUsageClient.parseHardLimit(["hardLimit": 0]))
        XCTAssertEqual(CursorUsageClient.parseCycleEnd(["nextCycleStart": "1787190945000"]), 1787190945000)
        XCTAssertNil(CursorUsageClient.parseCycleEnd([:]))
    }
}
