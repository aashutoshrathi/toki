import XCTest
@testable import Toki

// Guards against the failure mode where adding a preference silently wipes user data.
//
// AppPreferences' synthesized decoder required every CodingKey to be present, so an older
// state file - written before a newly added field existed - failed to decode. StateLoader
// catches that and falls back to an empty state, and the next save overwrites the file. One
// new field therefore destroyed accumulated history. These tests decode state shaped like an
// older release to make sure that stays fixed.
final class StateCompatibilityTests: XCTestCase {
    private func decodeState(_ json: String) throws -> UsageState {
        try JSONDecoder.toki.decode(UsageState.self, from: Data(json.utf8))
    }

    // The exact shape that broke: preferences with no notchModeEnabled key.
    func testStateFromBeforeNotchModeStillDecodes() throws {
        let json = """
        {
          "preferences": {
            "notificationsEnabled": true,
            "dndEnabled": false,
            "lowQuotaThreshold": 0.2,
            "notificationCooldownMinutes": 90,
            "menuBarMode": "smart",
            "historyRetentionDays": 14,
            "sessionWarningThreshold": 0.15
          },
          "history": [
            {"id":"6C7E4C8E-0000-0000-0000-000000000001","timestamp":"2026-07-01T10:00:00Z","accountID":"a","accountName":"A","provider":"claudeCode","remainingRatio":0.5,"primary":"x"}
          ]
        }
        """
        let state = try decodeState(json)
        XCTAssertEqual(state.history.count, 1, "history must survive a preferences field being added")
        XCTAssertEqual(state.preferences.historyRetentionDays, 14, "existing values must be preserved")
        XCTAssertFalse(state.preferences.notchModeEnabled, "a missing field must fall back to its default")
    }

    // The general rule, not just the one field: any subset of preferences must decode.
    func testPreferencesDecodeFromAnEmptyObject() throws {
        let state = try decodeState(#"{"preferences":{}}"#)
        XCTAssertEqual(state.preferences, AppPreferences())
    }

    func testPreferencesDecodeFromASingleKnownField() throws {
        let state = try decodeState(#"{"preferences":{"dndEnabled":true}}"#)
        XCTAssertTrue(state.preferences.dndEnabled)
        XCTAssertEqual(state.preferences.historyRetentionDays, AppPreferences().historyRetentionDays)
    }

    func testUnknownFutureFieldsAreIgnored() throws {
        let state = try decodeState(#"{"preferences":{"somethingFromALaterRelease":42}}"#)
        XCTAssertEqual(state.preferences, AppPreferences())
    }

    func testPreferencesSurviveARoundTrip() throws {
        var preferences = AppPreferences()
        preferences.notchModeEnabled = true
        preferences.historyRetentionDays = 21
        let data = try JSONEncoder.toki.encode(preferences)
        XCTAssertEqual(try JSONDecoder.toki.decode(AppPreferences.self, from: data), preferences)
    }
}
