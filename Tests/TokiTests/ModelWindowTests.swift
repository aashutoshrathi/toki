import XCTest
@testable import Toki

// A weekly limit scoped to one model is a separate allowance, not a slice of the shared week:
// spending the Fable week leaves the shared one untouched, so they have to be reported apart.
//
// The shapes below are the ones api/oauth/usage actually returns. The response does carry these
// up top as well, but as codenames (seven_day_omelette, seven_day_tangelo) that name no model,
// so `limits` is what gets parsed. Note `scope` is an object, not a string - reading it as a
// string matches nothing and silently drops every model window.
final class ModelWindowTests: XCTestCase {
    private func usage(limits: [[String: Any]]) -> ClaudeCodeUsage {
        ClaudeCodeUsage(json: [
            "five_hour": ["utilization": 20, "resets_at": NSNull()],
            "seven_day": ["utilization": 40, "resets_at": NSNull()],
            "limits": limits
        ])
    }

    private func scoped(_ displayName: String, percent: Int) -> [String: Any] {
        ["kind": "weekly_scoped", "group": "weekly", "percent": percent,
         "scope": ["model": ["display_name": displayName]]]
    }

    // The compact header row fits two columns; a third wraps its label and truncates its value,
    // so a model limit belongs in the detail list beside 5h, 7d and Extra.
    func testAModelLimitBecomesADetailLine() {
        let u = usage(limits: [scoped("Fable 5", percent: 30)])
        let line = u.metrics.first { $0.label == "Fable 5 7d" }
        XCTAssertNotNil(line, "the model limit has to reach the detail list")
        XCTAssertEqual(line?.value, "30% used", "written like the 5h and 7d lines, which report used")
    }

    func testTheDetailLineCarriesTheResetWhenThereIsOne() {
        let u = ClaudeCodeUsage(json: ["limits": [[
            "kind": "weekly_scoped", "group": "weekly", "percent": 30,
            "resets_at": "2099-01-01T00:00:00+00:00",
            "scope": ["model": ["display_name": "Fable 5"]]
        ]]])
        let value = u.metrics.first { $0.label == "Fable 5 7d" }?.value ?? ""
        XCTAssertTrue(value.hasPrefix("30% used - resets in "), "got \(value)")
    }

    func testAScopedWeeklyLimitReadsItsModelsDisplayName() {
        let u = usage(limits: [
            ["kind": "weekly_all", "group": "weekly", "scope": NSNull(), "percent": 46],
            scoped("Fable 5", percent: 30)
        ])
        XCTAssertEqual(u.modelWindows.count, 1)
        XCTAssertEqual(u.modelWindows.first?.label, "Fable 5 7d")
        XCTAssertEqual(u.modelWindows.first?.percentLeft, 70, "percent is used; the window reports what is left")
    }

    // The exact payload this account returns: session plus weekly_all, both unscoped.
    func testAnAccountWithoutModelLimitsGainsNoExtraWindows() {
        let u = usage(limits: [
            ["kind": "session", "group": "session", "scope": NSNull(), "percent": 24],
            ["kind": "weekly_all", "group": "weekly", "scope": NSNull(), "percent": 46]
        ])
        XCTAssertTrue(u.modelWindows.isEmpty)
        XCTAssertEqual(u.rateLimitWindows.map(\.label), ["5h", "7d"], "the shared windows are untouched")
    }

    // The shared weekly is already seven_day; counting it again would show one allowance twice.
    func testTheSharedWeeklyIsNeverTreatedAsAModelWindow() {
        let u = usage(limits: [[
            "kind": "weekly_all", "group": "weekly", "percent": 46,
            "scope": ["model": ["display_name": "Everything"]]
        ]])
        XCTAssertTrue(u.modelWindows.isEmpty)
    }

    func testASessionLimitIsNotAModelWindow() {
        let u = usage(limits: [["kind": "session", "group": "session", "percent": 10,
                                "scope": ["model": ["display_name": "Fable 5"]]]])
        XCTAssertTrue(u.modelWindows.isEmpty, "only weekly limits are a separate allowance")
    }

    func testEveryScopedWeeklyLimitIsKept() {
        let u = usage(limits: [scoped("Fable 5", percent: 30), scoped("Opus 4.5", percent: 80)])
        XCTAssertEqual(u.modelWindows.map(\.label), ["Fable 5 7d", "Opus 4.5 7d"])
        XCTAssertEqual(u.modelWindows.map(\.percentLeft), [70, 20])
    }

    // Reading scope as a string is the mistake that makes this silently do nothing.
    func testTheScopeIsReadAsAnObjectNotAString() {
        XCTAssertEqual(ClaudeCodeUsage.scopeName(["model": ["display_name": "Fable 5"]]), "Fable 5")
        XCTAssertNil(ClaudeCodeUsage.scopeName(NSNull()))
        XCTAssertNil(ClaudeCodeUsage.scopeName(["model": [:]]))
    }

    // Tolerated in case the shape is ever flattened, so a rename does not blank the row.
    func testAFlattenedScopeStillResolves() {
        XCTAssertEqual(ClaudeCodeUsage.scopeName("Fable 5"), "Fable 5")
        XCTAssertEqual(ClaudeCodeUsage.scopeName(["display_name": "Fable 5"]), "Fable 5")
    }

    func testAScopeWithNoNameIsSkipped() {
        let u = usage(limits: [["kind": "weekly_scoped", "group": "weekly", "percent": 30, "scope": NSNull()]])
        XCTAssertTrue(u.modelWindows.isEmpty)
    }

    func testAMissingPercentIsSkippedRatherThanReadAsZero() {
        var entry = scoped("Fable 5", percent: 0)
        entry.removeValue(forKey: "percent")
        XCTAssertTrue(usage(limits: [entry]).modelWindows.isEmpty, "no figure means no window, not a full one")
    }

    func testAResponseWithNoLimitsArrayIsUnchanged() {
        let u = ClaudeCodeUsage(json: ["five_hour": ["utilization": 20], "seven_day": ["utilization": 40]])
        XCTAssertTrue(u.modelWindows.isEmpty)
        XCTAssertEqual(u.rateLimitWindows.count, 2)
    }
}
