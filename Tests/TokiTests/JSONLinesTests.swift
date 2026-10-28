import XCTest
@testable import Toki

final class JSONLinesTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "toki-jsonl-\(UUID().uuidString).jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func append(_ text: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        handle.closeFile()
    }

    private func lines(from offset: UInt64 = 0) -> (lines: [String], end: UInt64?) {
        var lines: [String] = []
        let end = JSONLines.forEachLine(inFileAt: path, from: offset) { lines.append(String(decoding: $0, as: UTF8.self)) }
        return (lines, end)
    }

    func testLeavesALineStillBeingWrittenForTheNextRead() {
        append("{\"a\":1}\n{\"b\":")
        let first = lines()
        XCTAssertEqual(first.lines, [#"{"a":1}"#])
        XCTAssertEqual(first.end, 8)

        append("2}\n")
        let second = lines(from: first.end!)
        XCTAssertEqual(second.lines, [#"{"b":2}"#])
        XCTAssertEqual(second.end, 16)
    }

    func testReadsLinesThatSpanChunks() {
        let long = String(repeating: "x", count: 3 << 20)
        append("\(long)\nshort\n")
        let result = lines()
        XCTAssertEqual(result.lines.map(\.count), [long.count, 5])
    }

    func testMissingFileIsNil() {
        try? FileManager.default.removeItem(atPath: path)
        XCTAssertNil(lines().end)
    }

    func testClaudeSessionReadsOnlyTheLinesAddedSinceTheLastRead() throws {
        let turn = { (id: String) in
            #"{"type":"assistant","message":{"id":"\#(id)","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n"
        }
        append(turn("m1") + #"{"type":"ai-title","aiTitle":"First"}"# + "\n")
        let first = AgentSessionResolver.claudeSession(at: path, modified: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(first?.usage?.tokensInput, 10)
        XCTAssertEqual(first?.title, "First")

        append(turn("m1") + turn("m2") + #"{"type":"custom-title","customTitle":"Renamed"}"# + "\n")
        let second = AgentSessionResolver.claudeSession(at: path, modified: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(second?.usage?.tokensInput, 20)
        XCTAssertEqual(second?.usage?.tokensOutput, 10)
        XCTAssertEqual(second?.title, "Renamed")
    }

    func testClaudeSessionStartsOverWhenTheFileShrinks() throws {
        append(#"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}"# + "\n")
        _ = AgentSessionResolver.claudeSession(at: path, modified: Date(timeIntervalSince1970: 1))

        try Data(#"{"type":"ai-title","aiTitle":"New"}"#.utf8 + [0x0A]).write(to: URL(fileURLWithPath: path))
        let reread = AgentSessionResolver.claudeSession(at: path, modified: Date(timeIntervalSince1970: 2))
        XCTAssertNil(reread?.usage)
        XCTAssertEqual(reread?.title, "New")
    }
}
