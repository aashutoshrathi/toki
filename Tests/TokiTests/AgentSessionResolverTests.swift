import XCTest
@testable import Toki

final class AgentSessionResolverTests: XCTestCase {
    func testCustomTitleWinsOverInferredTitle() {
        let contents = """
        {"type":"summary","aiTitle":"Refactor the parser"}
        {"type":"summary","customTitle":"Parser rewrite","aiTitle":"Refactor the parser"}
        """
        XCTAssertEqual(AgentSessionResolver.claudeTitle(fromSessionContents: contents), "Parser rewrite")
    }

    func testInferredTitleUsedWhenNeverExplicitlyNamed() {
        let contents = #"{"type":"summary","aiTitle":"Refactor the parser"}"#
        XCTAssertEqual(AgentSessionResolver.claudeTitle(fromSessionContents: contents), "Refactor the parser")
    }

    func testLatestCustomTitleWinsAfterASecondRename() {
        let contents = """
        {"customTitle":"First name","aiTitle":"Inferred"}
        {"customTitle":"Second name"}
        """
        XCTAssertEqual(AgentSessionResolver.claudeTitle(fromSessionContents: contents), "Second name")
    }

    func testNoTitleFieldsYieldsNil() {
        XCTAssertNil(AgentSessionResolver.claudeTitle(fromSessionContents: #"{"type":"user","message":"hi"}"#))
    }

    func testProjectFolderNameMatchesClaudeCode() {
        XCTAssertEqual(AgentSessionResolver.projectFolderName("/Users/x/.t3/worktrees/go/main"), "-Users-x--t3-worktrees-go-main")
        XCTAssertEqual(AgentSessionResolver.projectFolderName("/tmp/🚀"), "-tmp---")
        let atLimit = "/tmp/" + String(repeating: "a", count: 195)
        XCTAssertEqual(AgentSessionResolver.projectFolderName(atLimit), "-tmp-" + String(repeating: "a", count: 195))
        let overLimit = "/tmp/" + String(repeating: "a", count: 196)
        XCTAssertEqual(AgentSessionResolver.projectFolderName(overLimit), "-tmp-" + String(repeating: "a", count: 195) + "-r0traf")
        let longWithEmoji = "/Users/x/" + String(repeating: "b", count: 300) + "/é🚀"
        XCTAssertTrue(AgentSessionResolver.projectFolderName(longWithEmoji).hasSuffix("bbbbbb-sz4ru"))
    }

    func testHostAppMatchesRexServerAndAppBundles() {
        let rexServerPath = "/users/pupa/library/application support/com.superlogical.rex/rexserver/versions/current/rex server.app/contents/macos/rex"
        XCTAssertEqual(HostApp.match(comm: rexServerPath), HostApp.rex)
        XCTAssertEqual(HostApp.match(comm: "/applications/rex.app/contents/macos/rex"), HostApp.rex)
        XCTAssertNil(HostApp.match(comm: "/usr/local/bin/myrex"))
        XCTAssertNil(HostApp.match(comm: "/applications/forex.app/contents/macos/forex"))
    }

    func testRexEnvironmentParsesTailEnvVarsAndRejectsUnsafeValues() {
        // Prompt text in argv may mention REX_BLOCK; the real env vars appear at the tail of `ps -E`.
        let output = """
        /Users/me/.local/bin/agy -i inspect REX_BLOCK=block:fake-from-argv PATH=/usr/bin REX_BLOCK=block:01a22155-9ff7-79eb-9d17-87e13f3572ca REX_SERVER=unix:///Users/me/Library/Application%20Support/rex/server.sock
        """
        let env = AgentSessionResolver.rexEnvironment(fromPSOutput: output)
        XCTAssertEqual(env?.blockID, "block:01a22155-9ff7-79eb-9d17-87e13f3572ca")
        XCTAssertEqual(env?.server, "unix:///Users/me/Library/Application%20Support/rex/server.sock")

        XCTAssertNil(AgentSessionResolver.rexEnvironment(fromPSOutput: "claude REX_BLOCK=../bad"))
        let flagServer = AgentSessionResolver.rexEnvironment(
            fromPSOutput: "claude REX_BLOCK=block:abc123 REX_SERVER=--malicious"
        )
        XCTAssertEqual(flagServer?.blockID, "block:abc123")
        XCTAssertNil(flagServer?.server)
    }

    func testRexCLIBaseArgumentsAlwaysDisableAutostart() {
        XCTAssertEqual(RexCLI.baseArguments(server: nil), ["--autostart=false"])
        XCTAssertEqual(
            RexCLI.baseArguments(server: "unix:///tmp/rex.sock"),
            ["--autostart=false", "-S", "unix:///tmp/rex.sock"]
        )
        XCTAssertEqual(RexCLI.baseArguments(server: "--flag"), ["--autostart=false"])
    }
}
