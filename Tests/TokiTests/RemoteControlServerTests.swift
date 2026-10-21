import Foundation
import XCTest
@testable import Toki

@MainActor
final class RemoteControlServerTests: XCTestCase {
    func testTheRecommendedOptionsAreTheOnesWithNoThirdParty() {
        // Tailscale is private by construction, and serving the app from this Mac means no web
        // server sits between the phone and the terminal it can type into.
        XCTAssertEqual(RemoteControlServer.HostMode.tailscale.label, "Tailscale (Recommended)")
        XCTAssertEqual(
            RemoteControlServer.CompanionAppMode.sameHost.label,
            "Same as host (Recommended)"
        )
        // The two that widen exposure say so in the name rather than reading as neutral choices.
        XCTAssertEqual(RemoteControlServer.HostMode.tunnel.label, "Cloudflare Tunnel (public)")
        XCTAssertEqual(RemoteControlServer.CompanionAppMode.hosted.label, "Toki RC (hosted)")
    }

    func testThePublicTunnelIsOfferedLastNotFirst() {
        XCTAssertEqual(
            RemoteControlServer.orderedHostModes(
                tailscaleAvailable: true,
                cloudflaredAvailable: true
            ),
            [.tailscale, .localNetwork, .localhost, .custom, .tunnel]
        )
        // Even with nothing private available it stays the last resort, never the default.
        XCTAssertEqual(
            RemoteControlServer.orderedHostModes(
                tailscaleAvailable: false,
                cloudflaredAvailable: true
            ).last,
            .tunnel
        )
        XCTAssertEqual(
            RemoteControlServer.preferredHostMode(
                tailscaleAvailable: false,
                localNetworkAvailable: false
            ),
            .localhost
        )
    }

    func testPairedDevicesArriveOnTheServersOwnPipe() {
        let line = """
        devices={"devices": [{"id": "a1b2c3d4", "name": "iPhone (Safari)", "ip": "100.101.102.103", \
        "proxied": false, "paired": 1000, "seen": 1200, "expires": 44200}]}
        """
        let devices = RemoteControlServer.parseDeviceLine(line)
        XCTAssertEqual(devices?.count, 1)
        XCTAssertEqual(devices?.first?.id, "a1b2c3d4")
        XCTAssertEqual(devices?.first?.name, "iPhone (Safari)")
        XCTAssertEqual(devices?.first?.seen, Date(timeIntervalSince1970: 1200))
        XCTAssertFalse(devices?.first?.proxied ?? true)

        XCTAssertNil(RemoteControlServer.parseDeviceLine("token=abc123"))
        XCTAssertNil(RemoteControlServer.parseDeviceLine("devices=not json"))
    }

    func testAProxiedDeviceDoesNotClaimAnAddressItCannotKnow() {
        // Behind `tailscale serve` the peer is this Mac, so showing 127.0.0.1 as the phone's
        // address would be a lie. The id is what actually names the session.
        let line = """
        devices={"devices": [{"id": "ff00ff00", "name": "iPad (Safari)", "ip": "127.0.0.1", \
        "proxied": true, "paired": 1000, "seen": 1200, "expires": 44200}]}
        """
        guard let device = RemoteControlServer.parseDeviceLine(line)?.first else {
            return XCTFail("expected one device")
        }
        let detail = SettingsPanel.deviceDetail(device)
        XCTAssertTrue(detail.contains("via proxy"), detail)
        XCTAssertFalse(detail.contains("127.0.0.1"), detail)
        XCTAssertTrue(detail.contains("ff00ff00"), detail)
    }

    func testEachHostModeNarrowsTheServerToWhatItNeeds() {
        // The Host setting is the user's statement about who should be able to reach this Mac, so
        // it has to reach the server as an access policy. Binding alone cannot say it: Tailscale
        // needs both loopback (for `tailscale serve`) and the 100.x address (for a phone).
        XCTAssertEqual(RemoteControlServer.reach(for: .localhost).access, "loopback")
        XCTAssertEqual(RemoteControlServer.reach(for: .localhost).bind, "127.0.0.1")
        // The tunnel only ever sees loopback peers too, but it needs its own policy: it is the
        // one mode where a relay carrying someone in from the internet is the point, and
        // Localhost must keep meaning this Mac even when something here relays for a stranger.
        XCTAssertEqual(RemoteControlServer.reach(for: .tunnel).access, "tunnel")
        XCTAssertEqual(RemoteControlServer.reach(for: .tunnel).bind, "127.0.0.1")
        XCTAssertEqual(RemoteControlServer.reach(for: .tailscale).access, "tailnet")
        XCTAssertEqual(RemoteControlServer.reach(for: .localNetwork).access, "private")
        XCTAssertEqual(RemoteControlServer.reach(for: .custom).access, "any")
    }

    func testOnlyACustomHostIsNamedToTheServer() {
        // Everything else Toki hands out is a shape the server already recognises; a custom host
        // is not, and would otherwise be rejected by the anti-rebinding check as an unknown name.
        XCTAssertEqual(
            RemoteControlServer.allowedHostArguments(for: .custom, customHost: " mac.internal "),
            ["--allow-host", "mac.internal"]
        )
        XCTAssertEqual(RemoteControlServer.allowedHostArguments(for: .custom, customHost: "  "), [])
        XCTAssertEqual(
            RemoteControlServer.allowedHostArguments(for: .tailscale, customHost: "mac.internal"),
            []
        )
    }

    func testRemoteProviderNamesMatchServerProtocol() {
        XCTAssertEqual(RemoteControlServer.remoteProviderName(for: .codex), "codex")
        XCTAssertEqual(RemoteControlServer.remoteProviderName(for: .claudeCode), "claude")
        XCTAssertEqual(RemoteControlServer.remoteProviderName(for: .openCode), "opencode")
        XCTAssertEqual(RemoteControlServer.remoteProviderName(for: .sarvamCode), "sarvam")
        XCTAssertNil(RemoteControlServer.remoteProviderName(for: .cursor))
    }

    func testSessionLifetimeDefaultsAndStopsAtTwoDays() {
        XCTAssertEqual(
            RemoteControlServer.SessionLifetime.twelveHours.label,
            "12 hours (Recommended)"
        )
        XCTAssertEqual(
            RemoteControlServer.SessionLifetime.allCases.map(\.rawValue).max(),
            2 * 24 * 60 * 60
        )
    }

    func testTailscaleIsPreferredAndLocalNetworkIsSecond() {
        XCTAssertEqual(
            RemoteControlServer.orderedHostModes(tailscaleAvailable: true),
            [.tailscale, .localNetwork, .localhost, .custom]
        )

        XCTAssertEqual(
            RemoteControlServer.preferredHostMode(
                tailscaleAvailable: true,
                localNetworkAvailable: true
            ),
            .tailscale
        )
    }

    func testLocalNetworkIsFallbackWhenTailscaleIsUnavailable() {
        XCTAssertEqual(
            RemoteControlServer.orderedHostModes(tailscaleAvailable: false),
            [.localNetwork, .localhost, .custom]
        )
        XCTAssertEqual(
            RemoteControlServer.preferredHostMode(
                tailscaleAvailable: false,
                localNetworkAvailable: true
            ),
            .localNetwork
        )
    }

    func testTailscaleDNSNameIsReadAndTrailingDotRemoved() {
        let data = Data(#"{"Self":{"DNSName":"my-mac.example-tailnet.ts.net."}}"#.utf8)

        XCTAssertEqual(
            RemoteControlServer.tailscaleDNSName(from: data),
            "my-mac.example-tailnet.ts.net"
        )
    }

    func testTailscaleDNSNameRejectsNonTailnetHost() {
        let data = Data(#"{"Self":{"DNSName":"attacker.example.com."}}"#.utf8)

        XCTAssertNil(RemoteControlServer.tailscaleDNSName(from: data))
    }

    func testTailscaleDNSNameHandlesMissingSelfNode() {
        let data = Data(#"{"BackendState":"Stopped"}"#.utf8)

        XCTAssertNil(RemoteControlServer.tailscaleDNSName(from: data))
    }

    func testTailscaleDNSNameSurvivesAVersionSkewWarningPrefix() {
        let data = Data("""
        Warning: client version "1.98.5" != tailscaled server version "1.102.2"
        {"Self":{"DNSName":"my-mac.example-tailnet.ts.net."}}
        """.utf8)

        XCTAssertEqual(
            RemoteControlServer.tailscaleDNSName(from: data),
            "my-mac.example-tailnet.ts.net"
        )
    }

    func testStatusDiagnosticTreatsTheGUIWrapperErrorAsUnreadable() {
        let data = Data("The Tailscale GUI failed to start: The operation couldn’t be completed. (Tailscale.CLIError error 3.)".utf8)

        XCTAssertEqual(
            RemoteControlServer.statusDiagnostic(from: data),
            "Couldn't read Tailscale's status. Enter the host by hand."
        )
    }

    func testServeStateSurvivesAVersionSkewWarningPrefix() {
        let json = """
        Warning: client version "1.98.5" != tailscaled server version "1.102.2"
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertEqual(serveState(json), .ready)
    }

    func testServeStateReportsGUIWrapperErrorAsUnreadable() {
        let data = Data("The Tailscale GUI failed to start: The operation couldn’t be completed. (Tailscale.CLIError error 3.)".utf8)

        guard case .unreadable = RemoteControlServer.serveState(from: data, port: 8765) else {
            return XCTFail("expected unreadable for non-JSON serve output")
        }
    }

    func testTailscaleConnectURLUsesHostedUIAndEncodesParameters() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .hosted,
            hostMode: .tailscale,
            host: "my-mac.example-tailnet.ts.net",
            localNetworkHost: "192.168.1.10",
            token: "token with spaces",
            port: 8765
        )

        XCTAssertEqual(
            url,
            "https://rc.toki.aashutosh.dev/#host=my-mac.example-tailnet.ts.net&token=token%20with%20spaces"
        )
    }

    func testSameHostConnectURLRemainsDirectAndSameOrigin() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .sameHost,
            hostMode: .localNetwork,
            host: "192.168.1.10",
            localNetworkHost: "192.168.1.10",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "http://192.168.1.10:8765/?token=abc")
    }

    func testSameTailscaleHostUsesItsHTTPSServedUI() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .sameHost,
            hostMode: .tailscale,
            host: "my-mac.example-tailnet.ts.net",
            localNetworkHost: "192.168.1.10",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "https://my-mac.example-tailnet.ts.net/?token=abc")
    }

    func testTailscaleFallsBackToDirectTailnetIPWhenDNSNameMissing() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .sameHost,
            hostMode: .tailscale,
            host: nil,
            localNetworkHost: "192.168.1.10",
            tailscaleIP: "100.101.102.103",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "http://100.101.102.103:8765/?token=abc")
    }

    func testHostedTailscaleFallsBackToDirectTailnetIPWhenDNSNameMissing() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .hosted,
            hostMode: .tailscale,
            host: nil,
            localNetworkHost: nil,
            tailscaleIP: "100.101.102.103",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "http://100.101.102.103:8765/?token=abc")
    }

    func testTailscaleWithoutDNSNameOrTailnetIPHasNoURL() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .sameHost,
            hostMode: .tailscale,
            host: nil,
            localNetworkHost: "192.168.1.10",
            tailscaleIP: nil,
            token: "abc",
            port: 8765
        )

        XCTAssertNil(url)
    }

    func testLocalhostCompanionOverridesSelectedHost() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .localhost,
            hostMode: .tailscale,
            host: "my-mac.example-tailnet.ts.net",
            localNetworkHost: "192.168.1.10",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "http://localhost:8765/?token=abc")
    }

    func testLocalNetworkCompanionUsesDetectedLANAddress() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .localNetwork,
            hostMode: .localhost,
            host: "localhost",
            localNetworkHost: "192.168.1.10",
            token: "abc",
            port: 8765
        )

        XCTAssertEqual(url, "http://192.168.1.10:8765/?token=abc")
    }

    func testHostedCompanionRejectsPlainLANHost() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .hosted,
            hostMode: .localNetwork,
            host: "192.168.1.10",
            localNetworkHost: "192.168.1.10",
            token: "abc",
            port: 8765
        )

        XCTAssertNil(url)
    }

    func testStatusDiagnosticReportsDisconnectedBackend() {
        let json = #"{"BackendState":"Stopped","Self":{"DNSName":""}}"#
        let message = RemoteControlServer.statusDiagnostic(from: Data(json.utf8))
        XCTAssertTrue(message.contains("isn't connected"), message)
        XCTAssertTrue(message.contains("Stopped"), message)
    }

    func testStatusDiagnosticReportsMagicDNSOffWhenRunningWithoutName() {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"macbook"}}"#
        let message = RemoteControlServer.statusDiagnostic(from: Data(json.utf8))
        XCTAssertTrue(message.contains("MagicDNS is off"), message)
    }

    func testStatusDiagnosticDoesNotBlameMagicDNSForUnreadableStatus() {
        for json in ["", "not json at all", "[]"] {
            let message = RemoteControlServer.statusDiagnostic(from: Data(json.utf8))
            XCTAssertFalse(message.contains("MagicDNS"), "\(json) -> \(message)")
            XCTAssertTrue(message.contains("Couldn't read"), "\(json) -> \(message)")
        }
    }

    func testStatusDiagnosticDoesNotBlameMagicDNSWhenSelfNodeIsAbsent() {
        let json = #"{"BackendState":"Running"}"#
        let message = RemoteControlServer.statusDiagnostic(from: Data(json.utf8))
        XCTAssertFalse(message.contains("MagicDNS"), message)
        XCTAssertTrue(message.contains("didn't report a name"), message)
    }

    func testStatusDiagnosticNamesANonTailnetHostInsteadOfBlamingMagicDNS() {
        let json = #"{"BackendState":"Running","Self":{"DNSName":"my-mac.example.com."}}"#
        let message = RemoteControlServer.statusDiagnostic(from: Data(json.utf8))
        XCTAssertFalse(message.contains("MagicDNS"), message)
        XCTAssertTrue(message.contains("my-mac.example.com"), message)
    }

    func testHandEnteredTailnetNameCountsAsAUsableHost() {
        XCTAssertTrue(
            RemoteControlServer.isUsableTailscaleHost(
                detected: nil,
                manual: "  sanji.tailaa723f.ts.net  "
            )
        )
        XCTAssertTrue(
            RemoteControlServer.isUsableTailscaleHost(detected: nil, manual: "SANJI.EXAMPLE.TS.NET")
        )
        XCTAssertTrue(
            RemoteControlServer.isUsableTailscaleHost(detected: "auto.example.ts.net", manual: "")
        )
    }

    func testBlankOrNonTailnetManualHostLeavesTheHintInPlace() {
        XCTAssertFalse(RemoteControlServer.isUsableTailscaleHost(detected: nil, manual: ""))
        XCTAssertFalse(RemoteControlServer.isUsableTailscaleHost(detected: nil, manual: "   "))
        XCTAssertFalse(RemoteControlServer.isUsableTailscaleHost(detected: nil, manual: "my-mac"))
        XCTAssertFalse(
            RemoteControlServer.isUsableTailscaleHost(detected: nil, manual: "attacker.example.com")
        )
    }

    private func serveState(_ json: String, port: Int = 8765) -> RemoteControlServer.ServeState {
        RemoteControlServer.serveState(from: Data(json.utf8), port: port)
    }

    func testServeReadyDetectsHandlerForOurPort() {
        XCTAssertEqual(serveState("""
        {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """), .ready)
    }

    // Spellings Tailscale may use for the same thing; matching one literal read a working serve as absent.
    func testServeReadyAcceptsEveryWayOfSpellingThisMac() {
        for proxy in ["http://127.0.0.1:8765", "127.0.0.1:8765", "http://localhost:8765",
                      "https://localhost:8765/", "http://[::1]:8765", "http+insecure://127.0.0.1:8765"] {
            XCTAssertEqual(
                serveState("{\"Web\":{\"mac.tail1234.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"\(proxy)\"}}}}}"),
                .ready,
                "\(proxy) points at this Mac and should count as served"
            )
        }
    }

    // Ours may not be the only handler on 443; finding it anywhere is what matters.
    func testServeReadyFindsOurPortOnANonRootPath() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Text":"hi"},"/toki":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """), .ready)
    }

    func testServeStateIsNotServingForADifferentPort() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/other":{"Proxy":"http://127.0.0.1:9999"}}}}}
        """), .notServing)
    }

    func testServeStateIgnoresHandlersThatAreNotOn443() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """), .notServing)
    }

    func testServeStateIsNotServingForAnEmptyConfig() {
        XCTAssertEqual(serveState("{}"), .notServing)
    }

    // The distinction the UI was missing: nothing served is a fact, an unreadable status is not.
    func testUnreadableStatusIsNotReportedAsNotServing() {
        XCTAssertEqual(RemoteControlServer.serveState(from: nil, port: 8765),
                       .unreadable("Toki couldn't read `tailscale serve status`."))
        guard case .unreadable = serveState("not json at all") else {
            return XCTFail("unparseable output must not read as a working answer")
        }
    }

    func testServeConflictWhenRootServesAnotherApp() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
        """), .conflict)
    }

    func testAStaticRootHandlerIsAConflictToo() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Text":"hello"}}}}}
        """), .conflict)
    }

    func testNoConflictWhenRootIsOurPort() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """), .ready)
    }

    func testNoConflictWhenNothingIsOn443() {
        XCTAssertEqual(serveState("{}"), .notServing)
    }

    func testAStaticPathRootHandlerIsAConflict() {
        XCTAssertEqual(serveState("""
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Path":"/var/www/site"}}}}}
        """), .conflict)
    }

    // When `tailscale status` can't be read, serve's own config still names the Mac.
    func testTheServedHostIsLearnedFromServeStatus() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertEqual(
            RemoteControlServer.servedTailscaleHost(from: Data(json.utf8)),
            "mac.tail1234.ts.net"
        )
    }

    func testAServedHostThatIsNotATailnetNameIsIgnored() {
        let json = """
        {"Web":{"attacker.example.com:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertNil(RemoteControlServer.servedTailscaleHost(from: Data(json.utf8)))
        XCTAssertNil(RemoteControlServer.servedTailscaleHost(from: nil))
    }

    private let usageNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let usageWeek: TimeInterval = 7 * 86_400

    // The payload is built from the snapshots, so the phone shows the same reading as the menu bar.
    func testUsagePayloadCarriesTheReadingTheMenuBarShows() {
        var snapshot = AccountSnapshot(
            id: "claude-code", name: "Claude Code", provider: .claudeCode,
            primary: "62%", subtitle: "resets in 2h", remainingRatio: 0.62, metrics: []
        )
        snapshot.menuBarValue = nil
        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload[0]["id"] as? String, "claude-code")
        XCTAssertEqual(payload[0]["remaining"] as? Double, 0.62)
        XCTAssertEqual(payload[0]["detail"] as? String, "resets in 2h")
        XCTAssertEqual(payload[0]["error"] as? Bool, false)
    }

    // No quota API (Grok, Copilot) or a cost figure instead: a placeholder ratio would draw a bar for nothing.
    func testAnAccountWithNoQuotaSendsNoRatio() {
        var snapshot = AccountSnapshot(
            id: "grok", name: "Grok", provider: .grok,
            primary: "active", subtitle: "", remainingRatio: nil, metrics: []
        )
        snapshot.menuBarValue = "$1.20"
        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)
        XCTAssertNil(payload[0]["remaining"])
        XCTAssertNil(payload[0]["detail"])
        XCTAssertEqual(payload[0]["value"] as? String, "$1.20")
    }

    // A banked reset reaches the phone, so it can be spent from there as well as from the card.
    func testUsagePayloadCarriesABankedReset() {
        let expiry = Date(timeIntervalSince1970: 1_792_000_000)
        var snapshot = AccountSnapshot(
            id: "claude-1-me@example.com", name: "Claude Code", provider: .claudeCode,
            primary: "62%", subtitle: "resets in 2h", remainingRatio: 0.62, metrics: []
        )
        snapshot.resetCreditsAvailable = 2
        snapshot.resetCreditExpiry = expiry

        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)

        XCTAssertEqual(payload[0]["resets"] as? Int, 2)
        XCTAssertEqual(payload[0]["resetExpiry"] as? String, ISO8601DateFormatter().string(from: expiry))
    }

    // Absent rather than zero, so the phone never draws a redeem control for a reset nobody holds.
    func testUsagePayloadOmitsResetsWhenThereAreNone() {
        let snapshot = AccountSnapshot(
            id: "codex", name: "Codex", provider: .codex,
            primary: "90%", subtitle: "", remainingRatio: 0.9, metrics: []
        )
        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)

        XCTAssertNil(payload[0]["resets"])
        XCTAssertNil(payload[0]["resetExpiry"])
    }

    private func codexSnapshot(weeklyLeft: Int) -> AccountSnapshot {
        var snapshot = AccountSnapshot(
            id: "codex", name: "Codex", provider: .codex,
            primary: "90%", subtitle: "", remainingRatio: 0.9, metrics: []
        )
        snapshot.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 90, resetHint: nil)
        snapshot.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: weeklyLeft, resetHint: nil)
        return snapshot
    }

    // The phone draws the same bars as the card, so it needs the same windows in the same order.
    func testUsagePayloadListsEachQuotaWindowInCardOrder() throws {
        var snapshot = AccountSnapshot(
            id: "claude-code", name: "Claude Code", provider: .claudeCode,
            primary: "62%", subtitle: "", remainingRatio: 0.62, metrics: []
        )
        snapshot.primaryWindow = RateLimitWindow(label: "5h", percentLeft: 62, resetHint: "resets in 2h (3:00 PM)")
        snapshot.secondaryWindow = RateLimitWindow(label: "7d", percentLeft: 40, resetHint: nil)
        snapshot.modelWindows = [RateLimitWindow(label: "Fable 5 7d", percentLeft: 70, resetHint: "resets in 3d")]

        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)
        let windows = try XCTUnwrap(payload[0]["windows"] as? [[String: Any]])

        XCTAssertEqual(windows.map { $0["label"] as? String }, ["5h", "7d", "Fable 5 7d"])
        XCTAssertEqual(windows.map { $0["left"] as? Int }, [62, 40, 70])
        XCTAssertEqual(windows.map { $0["reset"] as? String }, ["in 2h", nil, "in 3d"])
    }

    func testUsagePayloadCarriesPaceOnlyWhenTheWindowKnowsItsLength() throws {
        var snapshot = codexSnapshot(weeklyLeft: 30)
        snapshot.secondaryWindow = RateLimitWindow(
            label: "7d", percentLeft: 30, resetHint: nil,
            resetAt: usageNow.addingTimeInterval(usageWeek / 2), duration: usageWeek
        )

        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)
        let windows = try XCTUnwrap(payload[0]["windows"] as? [[String: Any]])

        XCTAssertNil(windows[0]["pace"])
        XCTAssertNil(windows[0]["deviation"])
        XCTAssertEqual(try XCTUnwrap(windows[1]["pace"] as? Double), 0.5, accuracy: 0.0001)
        XCTAssertEqual(windows[1]["deviation"] as? Int, 20)
    }

    func testUsagePayloadMarksWhereTheWeeklyAutoResetFires() throws {
        var preferences = AppPreferences()
        preferences.autoResetEnabled = true
        preferences.autoResetWeeklyPercentLeft = 1

        let payload = RemoteControlServer.usagePayload(from: [codexSnapshot(weeklyLeft: 50)], preferences: preferences, now: usageNow)
        let windows = try XCTUnwrap(payload[0]["windows"] as? [[String: Any]])

        XCTAssertNil(windows[0]["autoReset"])
        XCTAssertEqual(try XCTUnwrap(windows[1]["autoReset"] as? Double), 0.99, accuracy: 0.0001)
    }

    func testUsagePayloadHasNoAutoResetMarkerWhileAutoResetIsOff() throws {
        let payload = RemoteControlServer.usagePayload(from: [codexSnapshot(weeklyLeft: 50)], preferences: AppPreferences(), now: usageNow)
        let windows = try XCTUnwrap(payload[0]["windows"] as? [[String: Any]])

        XCTAssertNil(windows[0]["autoReset"])
        XCTAssertNil(windows[1]["autoReset"])
    }

    // Older phone UIs and cost-only accounts keep the single bar, so there is no empty list to misread.
    func testUsagePayloadOmitsWindowsWhenAnAccountHasNone() {
        let snapshot = AccountSnapshot(
            id: "codex", name: "Codex", provider: .codex,
            primary: "90%", subtitle: "", remainingRatio: 0.9, metrics: []
        )
        let payload = RemoteControlServer.usagePayload(from: [snapshot], preferences: AppPreferences(), now: usageNow)

        XCTAssertNil(payload[0]["windows"])
    }

    func testParseResetLineReadsOnlyARedeemRequest() {
        XCTAssertEqual(RemoteControlServer.parseResetLine("reset=claude-1-me@example.com"), "claude-1-me@example.com")
        XCTAssertEqual(RemoteControlServer.parseResetLine("reset=codex  "), "codex")
        XCTAssertNil(RemoteControlServer.parseResetLine("reset="))
        XCTAssertNil(RemoteControlServer.parseResetLine("token=abc123"))
        XCTAssertNil(RemoteControlServer.parseResetLine("devices=[]"))
    }

    func testParseTunnelHostFromCloudflaredOutput() {
        let text = """
        2026-07-29T10:00:00Z INF +----------------------------------------------------+
        2026-07-29T10:00:00Z INF |  Your quick Tunnel has been created! Visit it at:   |
        2026-07-29T10:00:00Z INF |  https://blue-green-fox-123.trycloudflare.com       |
        2026-07-29T10:00:00Z INF +----------------------------------------------------+
        """
        XCTAssertEqual(
            RemoteControlServer.parseTunnelHost(from: text),
            "blue-green-fox-123.trycloudflare.com"
        )
    }

    func testParseTunnelHostReturnsNilWithoutURL() {
        XCTAssertNil(RemoteControlServer.parseTunnelHost(from: "2026-07-29 INF starting tunnel"))
    }

    // Every refusal Toki can name should come back with the fix, not with Tailscale's stderr and
    // an invitation to work out which failure it was.
    func testNotBeingTheTailnetOperatorComesBackWithTheCommandThatFixesIt() {
        let failure = RemoteControlServer.serveFailure(
            launched: true,
            exitCode: 1,
            stderr: "access denied: serve config denied: this command must be run as root, or by the tailscale operator"
        )
        XCTAssertEqual(failure.remedy, "sudo tailscale set --operator=$USER")
        XCTAssertFalse(failure.isUnrecognized)
    }

    func testTailnetWithoutHTTPSCertificatesIsNamedAsTheCause() {
        let failure = RemoteControlServer.serveFailure(
            launched: true,
            exitCode: 1,
            stderr: "HTTPS is not enabled in the admin panel"
        )
        XCTAssertTrue(failure.message.contains("HTTPS certificates"))
        XCTAssertNil(failure.remedy)
        XCTAssertFalse(failure.isUnrecognized)
    }

    func testSignedOutTailscaleAsksForASignInRatherThanAnOperatorChange() {
        let failure = RemoteControlServer.serveFailure(
            launched: true, exitCode: 1, stderr: "not logged in, run `tailscale up`"
        )
        XCTAssertEqual(failure.remedy, "tailscale up")
    }

    func testAMissingCLIIsNotPresentedAsSomethingToRetry() {
        let failure = RemoteControlServer.serveFailure(launched: false, exitCode: -1, stderr: "")
        XCTAssertFalse(failure.isUnrecognized)
        XCTAssertNil(failure.remedy)
    }

    // Only an unattributable failure earns the second attempt with the older command form; a
    // refusal Toki understands would refuse that form too.
    func testAnUnfamiliarFailureIsTheOnlyOneWorthRetrying() {
        let unknown = RemoteControlServer.serveFailure(
            launched: true, exitCode: 1, stderr: "flag provided but not defined: -bg"
        )
        XCTAssertTrue(unknown.isUnrecognized)
        XCTAssertEqual(unknown.message, "flag provided but not defined: -bg")

        let timedOut = RemoteControlServer.serveFailure(
            launched: true, exitCode: -1, stderr: "timed out after 25s"
        )
        XCTAssertFalse(timedOut.isUnrecognized)
    }

    func testTunnelHostBuildsHTTPSConnectURL() {
        let url = RemoteControlServer.makeConnectURL(
            companionAppMode: .sameHost,
            hostMode: .tunnel,
            host: "blue-green-fox-123.trycloudflare.com",
            localNetworkHost: nil,
            token: "abc",
            port: 8765
        )
        XCTAssertEqual(url, "https://blue-green-fox-123.trycloudflare.com/?token=abc")
    }

    func testParseOpenLineReadsOnlyAPositiveProcessID() {
        XCTAssertEqual(RemoteControlServer.parseOpenLine("open=4242"), 4242)
        XCTAssertEqual(RemoteControlServer.parseOpenLine("open=4242  "), 4242)
        XCTAssertNil(RemoteControlServer.parseOpenLine("open="))
        XCTAssertNil(RemoteControlServer.parseOpenLine("open=0"))
        XCTAssertNil(RemoteControlServer.parseOpenLine("open=-7"))
        XCTAssertNil(RemoteControlServer.parseOpenLine("open=12ab"))
        XCTAssertNil(RemoteControlServer.parseOpenLine("open=2147483648"))
        XCTAssertNil(RemoteControlServer.parseOpenLine("reset=codex"))
        XCTAssertNil(RemoteControlServer.parseOpenLine("token=abc123"))
    }

    private func claudeAgent(pid: Int32, t3Thread: T3CodeThreadStore.Thread?) -> ActiveAgent {
        ActiveAgent(
            id: pid, provider: .claudeCode, directory: "/tmp/app", chatTitle: "Fix the build",
            hostApp: .t3Code, hostProcessID: nil, lastActivity: nil, processID: pid, runtime: "1:00",
            terminalTTY: nil, memoryKB: 1000, command: "claude", sessionUsage: nil, attention: nil,
            t3Thread: t3Thread
        )
    }

    func testAgentPayloadCarriesTheT3LinkAndPhonesOnlyForT3Agents() {
        let thread = T3CodeThreadStore.Thread(
            id: "thread-1", title: "Fix the build",
            url: URL(string: "t3code://threads/env-1/thread-1"), mobileOSes: ["Android"]
        )
        let payload = RemoteControlServer.agentPayload(from: [
            claudeAgent(pid: 10, t3Thread: thread),
            claudeAgent(pid: 11, t3Thread: nil)
        ])

        let t3 = payload[0]["t3"] as? [String: Any]
        XCTAssertEqual(t3?["link"] as? String, "t3code://threads/env-1/thread-1")
        XCTAssertEqual(t3?["mobile"] as? [String], ["Android"])
        XCTAssertNil(payload[1]["t3"])
    }

    func testAgentPayloadOmitsT3WhenTheThreadHasNoLink() {
        let thread = T3CodeThreadStore.Thread(id: "thread-1", title: nil, url: nil, mobileOSes: ["iOS"])
        let payload = RemoteControlServer.agentPayload(from: [claudeAgent(pid: 10, t3Thread: thread)])

        XCTAssertNil(payload[0]["t3"])
        XCTAssertEqual(payload[0]["pid"] as? Int32, 10)
    }
}
