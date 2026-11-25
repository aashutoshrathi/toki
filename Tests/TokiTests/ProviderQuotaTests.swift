import Foundation
import XCTest
@testable import Toki

final class ProviderQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let reset = "2027-01-17T04:00:00.123Z"

    func testCursorRequiresUnifiedCurrentIncludedAllowance() throws {
        var response: [String: Any] = [
            "isUnified": true,
            "usagePercent": 13.25,
            "hasNonZeroIncludedLimit": true,
            "nextResetTimestampUtc": reset
        ]
        let usage = try XCTUnwrap(CursorUsageClient.parseUnifiedUsage(response, now: now))
        XCTAssertEqual(usage.ratio, 0.8675, accuracy: 0.0001)
        XCTAssertEqual(usage.window.resetAt, resetDate(reset))
        response["usagePercent"] = false
        XCTAssertNil(CursorUsageClient.parseUnifiedUsage(response, now: now))
        response["usagePercent"] = 0
        XCTAssertEqual(CursorUsageClient.parseUnifiedUsage(response, now: now)?.ratio, 1)
        response["isUnified"] = false
        XCTAssertNil(CursorUsageClient.parseUnifiedUsage(response, now: now))
        response["isUnified"] = true
        response["includedLimitZero"] = true
        XCTAssertNil(CursorUsageClient.parseUnifiedUsage(response, now: now))
    }

    func testCursorOutageOnlyFallsBackForIdentifiedLegacyPlans() {
        XCTAssertTrue(CursorUsageClient.isLegacyMembership("PRO"))
        XCTAssertTrue(CursorUsageClient.isLegacyMembership("pro_plus"))
        XCTAssertFalse(CursorUsageClient.isLegacyMembership("premium"))
        XCTAssertFalse(CursorUsageClient.isLegacyMembership("ultra"))
        XCTAssertFalse(CursorUsageClient.isLegacyMembership(nil))
    }

    func testCursorCacheRequiresTheCurrentLoginAndAnUnexpiredWindow() throws {
        let reset = try XCTUnwrap(resetDate(self.reset))
        let snapshot = AccountSnapshot(
            id: "cursor", name: "Cursor", provider: .cursor, primary: "70% left", subtitle: "",
            remainingRatio: 0.7, metrics: [],
            primaryWindow: RateLimitWindow(label: "7d", percentLeft: 70, resetAt: reset),
            cursorIdentity: "user_example"
        )
        let same = CursorAuth.Login.connected(.init(token: "fixture", userId: "user_example"))
        let switched = CursorAuth.Login.connected(.init(token: "fixture", userId: "user_other"))
        XCTAssertEqual(CursorUsageClient.verifiedPrevious(snapshot, login: same, now: now), snapshot)
        XCTAssertNil(CursorUsageClient.verifiedPrevious(snapshot, login: switched, now: now))
        XCTAssertNil(CursorUsageClient.verifiedPrevious(snapshot, login: same, now: reset))
        XCTAssertNil(CursorUsageClient.verifiedPrevious(snapshot, login: .missing, now: now))
    }

    func testGrokSharesOnlyAVerifiedCursorAllowanceAndRetainsItsOwnReading() throws {
        let grokAccount = AccountConfig(id: "grok", name: "Grok", provider: .grok)
        let grokBilling: [String: Any] = [
            "subscription_tier": "Fixture Plan",
            "config": [
                "creditUsagePercent": 13,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": reset]
            ]
        ]
        var cursor = AccountSnapshot(
            id: "cursor", name: "Cursor", provider: .cursor, primary: "", subtitle: "",
            remainingRatio: 0.8675, metrics: [],
            primaryWindow: RateLimitWindow(label: "7d", percentLeft: 87, resetAt: resetDate(reset))
        )
        let grok = try XCTUnwrap(GrokUsageClient.snapshot(
            for: grokAccount, billing: grokBilling, email: "account@example.com", now: now
        ))
        XCTAssertEqual(emailAddress(in: grok), "account@example.com")
        XCTAssertEqual(grok.accountInfo.first { $0.label == "Plan" }?.value, "Fixture Plan")
        let standalone = RemoteControlServer.usagePayload(from: [grok], preferences: AppPreferences(), now: now)
        XCTAssertEqual(standalone.first?["detail"] as? String, "Fixture Plan")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: standalone), as: UTF8.self)
            .contains("account@example.com"))
        let cursorWindow = try XCTUnwrap(cursor.primaryWindow)
        cursor.weeklySubscriptionQuota = WeeklySubscriptionQuota(email: "someone@example.com", ratio: 0.8675, window: cursorWindow)
        XCTAssertEqual(UsageFetcher.reconcileSharedWeeklyQuota([cursor, grok])[1].remainingRatio, 0.87)

        cursor.weeklySubscriptionQuota = WeeklySubscriptionQuota(email: "Account@example.com", ratio: 0.8675, window: cursorWindow)
        let combined = UsageFetcher.reconcileSharedWeeklyQuota([cursor, grok])
        let shared = combined[1]
        XCTAssertEqual(shared.sharedWithCursorID, cursor.id)
        XCTAssertNil(shared.remainingRatio)
        XCTAssertNil(shared.primaryWindow)
        XCTAssertEqual(accountGroups(for: combined).map(\.provider), [.cursor])
        XCTAssertEqual(cursor.sessionProviders(among: combined), [.cursor, .grok])
        XCTAssertEqual(cursor.sharedDisplayName(among: combined), "Cursor & Grok")
        XCTAssertEqual(menuBarEntries(for: combined, mode: .pinned, pinnedProviders: [.grok, .cursor]).map(\.provider), [.cursor])
        XCTAssertEqual(menuBarEntries(for: combined, mode: .pinned, pinnedProviders: [.grok]).first?.accountLabel, "Cursor & Grok")
        let companion = RemoteControlServer.usagePayload(from: combined, preferences: AppPreferences(), now: now)
        XCTAssertEqual(companion.compactMap { $0["id"] as? String }, [cursor.id])
        let widget = WidgetDataStore.makeSnapshot(entries: [], awaitingInput: 0, snapshots: combined, updatedAt: now)
        XCTAssertEqual(widget.entries.map(\.displayName), ["Cursor & Grok"])
        XCTAssertEqual(UsageFetcher.reconcileSharedWeeklyQuota([shared])[0], grok)
    }

    func testGrokReadsIdentityOnlyFromAnUnambiguousCurrentCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authFile = root.appendingPathComponent("auth.json")
        let currentScope = "https://auth.example.com::current"
        let current = ["auth_mode": "oidc", "key": "fixture", "email": "current@example.com"]
        var cache = [
            "https://accounts.x.ai/sign-in": ["auth_mode": "web_login", "key": "fixture", "email": "stale@example.com"],
            currentScope: current,
        ]
        func readEmail() throws -> String? {
            try JSONSerialization.data(withJSONObject: cache).write(to: authFile)
            return try GrokCredentialReader.readCredentials(path: authFile.path, requiresUniqueAccount: true).email
        }
        XCTAssertEqual(try readEmail(), "current@example.com")

        cache[currentScope]?.removeValue(forKey: "email")
        XCTAssertNil(try readEmail())

        cache[currentScope] = current
        cache["https://auth.example.com::other"] = ["auth_mode": "oidc", "key": "fixture", "email": "other@example.com"]
        XCTAssertNil(try readEmail())
    }

    func testAntigravityEnablesSlashCommandsForUsageProbe() throws {
        let arguments = AntigravityUsageClient.usageArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Bool])
        XCTAssertEqual(settings["disableSlashCommands"], false)
        XCTAssertTrue(arguments.contains("/usage"))
    }

    func testAntigravityAvailabilityUsesTheBestGroupAfterApplyingItsTightestWindow() throws {
        let input = Data(#"""
        {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"window":"weekly","remaining_fraction":0.9995}, {"window":"5h","remaining_fraction":0.8}]},
          {"name":"Claude and GPT models","buckets":[
            {"window":"weekly","remaining_fraction":0}, {"window":"5h","remaining_fraction":0,"disabled":true}]}
        ]}}}
        """#.utf8)
        let account = AccountConfig(id: "agy", name: "Antigravity", provider: .antigravity)
        let snapshot = try XCTUnwrap(AntigravityUsageClient.snapshot(for: account, data: input, now: now))
        XCTAssertEqual(snapshot.remainingRatio, 0.8)
        XCTAssertFalse(allTrackedQuotaExhausted([snapshot]))
        let pinned = menuBarEntries(for: [snapshot], mode: .pinned, pinnedProviders: [.antigravity])
        XCTAssertEqual(pinned.first?.provider, .antigravity)
        XCTAssertEqual(pinned.first?.value, "80%")
        XCTAssertEqual(snapshot.modelWindows.map(\.label), ["Gemini Models 7d", "Gemini Models 5h", "Claude and GPT models 7d"])
        XCTAssertEqual(snapshot.modelWindows.map(\.duration), [604_800, 18_000, 604_800])
        XCTAssertTrue(snapshot.planWindows.isEmpty)
    }
}
