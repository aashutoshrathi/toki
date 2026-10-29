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
}
