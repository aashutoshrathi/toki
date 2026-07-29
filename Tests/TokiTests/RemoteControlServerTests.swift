import Foundation
import XCTest
@testable import Toki

@MainActor
final class RemoteControlServerTests: XCTestCase {
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
}
