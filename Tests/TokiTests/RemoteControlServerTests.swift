import Foundation
import XCTest
@testable import Toki

@MainActor
final class RemoteControlServerTests: XCTestCase {
    func testRecommendedHostAndAppLabels() {
        XCTAssertEqual(RemoteControlServer.HostMode.tailscale.label, "Tailscale (Recommended)")
        XCTAssertEqual(
            RemoteControlServer.CompanionAppMode.hosted.label,
            "Toki RC (Recommended)"
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
