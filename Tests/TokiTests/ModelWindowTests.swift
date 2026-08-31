import XCTest
@testable import Toki

// A weekly limit scoped to one model is a separate allowance, not a slice of the shared week:
// burning the Fable week leaves the shared one untouched, so they have to be reported apart.
//
// The top-level response carries these as codenames (seven_day_omelette, seven_day_tangelo)
// that say nothing about which model they belong to. `limits` describes itself, so that is what
// is parsed. The shapes below match a live api/oauth/usage response.
final class ModelWindowTests: XCTestCase {
    private func usage(limits: [[String: Any]]) -> ClaudeCodeUsage {
        ClaudeCodeUsage(json: [
            "five_hour": ["utilization": 20, "resets_at": NSNull()],
            "seven_day": ["utilization": 40, "resets_at": NSNull()],
            "limits": limits
        ])
    }

    // Exactly what an account with no model-scoped limits returns: session plus weekly_all,
    // both with a null scope. Nothing extra should appear.
    func testAnAccountWithoutModelLimitsGainsNoExtraWindows() {
        let u = usage(limits: [
            ["kind": "session", "group": "session", "scope": NSNull(), "percent": 24],
            ["kind": "weekly_all", "group": "weekly", "scope": NSNull(), "percent": 46]
        ])
        XCTAssertTrue(u.modelWindows.isEmpty)
        XCTAssertEqual(u.rateLimitWindows.map(\.label), ["5h", "7d"], "the shared windows are untouched")
    }

    func testAScopedWeeklyLimitBecomesItsOwnWindow() {
        let u = usage(limits: [
            ["kind": "weekly_all", "group": "weekly", "scope": NSNull(), "percent": 46],
            ["kind": "weekly_model", "group": "weekly", "scope": "claude-fable-5", "percent": 30]
        ])
        XCTAssertEqual(u.modelWindows.count, 1)
        XCTAssertEqual(u.modelWindows.first?.label, "Fable 5 7d")
        XCTAssertEqual(u.modelWindows.first?.percentLeft, 70, "percent is used, the window reports what is left")
    }

    // The shared weekly is already covered by seven_day; counting it twice would show the same
    // allowance in two columns.
    func testTheUnscopedWeeklyIsNotDuplicated() {
        let u = usage(limits: [["kind": "weekly_all", "group": "weekly", "scope": NSNull(), "percent": 46]])
        XCTAssertTrue(u.modelWindows.isEmpty)
    }

    func testTheSessionLimitIsNotTreatedAsAModelWindow() {
        let u = usage(limits: [["kind": "session", "group": "session", "scope": "claude-fable-5", "percent": 10]])
        XCTAssertTrue(u.modelWindows.isEmpty, "only weekly limits are a separate model allowance")
    }

    func testEveryScopedWeeklyLimitIsKept() {
        let u = usage(limits: [
            ["kind": "weekly_model", "group": "weekly", "scope": "claude-fable-5", "percent": 30],
            ["kind": "weekly_model", "group": "weekly", "scope": "claude-opus-4-5", "percent": 80]
        ])
        XCTAssertEqual(u.modelWindows.map(\.label), ["Fable 5 7d", "Opus 4 5 7d"])
        XCTAssertEqual(u.modelWindows.map(\.percentLeft), [70, 20])
    }

    // A model Toki has never heard of still has to render, since the scope is whatever the API
    // says it is.
    func testAnUnknownScopeStillRenders() {
        let u = usage(limits: [["kind": "weekly_model", "group": "weekly", "scope": "tangelo", "percent": 5]])
        XCTAssertEqual(u.modelWindows.first?.label, "Tangelo 7d")
        XCTAssertEqual(u.modelWindows.first?.percentLeft, 95)
    }

    func testAMissingPercentIsSkippedRatherThanReadAsZero() {
        let u = usage(limits: [["kind": "weekly_model", "group": "weekly", "scope": "claude-fable-5"]])
        XCTAssertTrue(u.modelWindows.isEmpty, "no figure means no window, not a full one")
    }

    func testAResponseWithNoLimitsArrayIsUnchanged() {
        let u = ClaudeCodeUsage(json: ["five_hour": ["utilization": 20], "seven_day": ["utilization": 40]])
        XCTAssertTrue(u.modelWindows.isEmpty)
        XCTAssertEqual(u.rateLimitWindows.count, 2)
    }

    func testLabelDropsTheProviderPrefixAndTidiesSeparators() {
        XCTAssertEqual(ClaudeCodeUsage.modelWindowLabel("claude-fable-5"), "Fable 5 7d")
        XCTAssertEqual(ClaudeCodeUsage.modelWindowLabel("opus"), "Opus 7d")
        XCTAssertEqual(ClaudeCodeUsage.modelWindowLabel("seven_day_sonnet"), "Seven Day Sonnet 7d")
    }
}
