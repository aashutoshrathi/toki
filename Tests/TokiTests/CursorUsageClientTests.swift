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
