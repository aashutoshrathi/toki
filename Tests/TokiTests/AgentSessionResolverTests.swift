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
}
