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

    func testServeReadyDetectsHandlerForOurPort() {
        let json = """
        {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertTrue(RemoteControlServer.serveReady(from: Data(json.utf8), port: 8765))
    }

    func testServeReadyFalseForDifferentPort() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
        """
        XCTAssertFalse(RemoteControlServer.serveReady(from: Data(json.utf8), port: 8765))
    }

    func testServeReadyFalseWhenNotServedOn443() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertFalse(RemoteControlServer.serveReady(from: Data(json.utf8), port: 8765))
    }

    func testServeReadyFalseForEmptyConfig() {
        XCTAssertFalse(RemoteControlServer.serveReady(from: Data("{}".utf8), port: 8765))
    }

    func testServeConflictWhenRootServesAnotherApp() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9999"}}}}}
        """
        XCTAssertTrue(RemoteControlServer.serveConflict(from: Data(json.utf8), port: 8765))
    }

    func testNoServeConflictWhenRootIsOurPort() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8765"}}}}}
        """
        XCTAssertFalse(RemoteControlServer.serveConflict(from: Data(json.utf8), port: 8765))
    }

    func testNoServeConflictWhenNothingOn443() {
        XCTAssertFalse(RemoteControlServer.serveConflict(from: Data("{}".utf8), port: 8765))
    }

    func testServeConflictWhenRootIsStaticHandler() {
        let json = """
        {"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Path":"/var/www/site"}}}}}
        """
        XCTAssertTrue(RemoteControlServer.serveConflict(from: Data(json.utf8), port: 8765))
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
}
