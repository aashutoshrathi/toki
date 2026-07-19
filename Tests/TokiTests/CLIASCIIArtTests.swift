import XCTest
@testable import Toki

final class CLIASCIIArtTests: XCTestCase {
    func testLogoHas14Lines() {
        XCTAssertEqual(tokiLogoLines.count, 14)
    }

    func testBannerHas3Lines() {
        XCTAssertEqual(tokiBannerLines.count, 3)
    }

    func testBannerContainsToki() {
        XCTAssertEqual(tokiBannerLines[0], "/toki")
    }

    func testBannerContainsVersion() {
        XCTAssertEqual(tokiBannerLines[1], "v\(appVersion)")
    }

    func testBannerContainsGitHub() {
        XCTAssertEqual(tokiBannerLines[2], "github.com/aashutoshrathi/toki")
    }

    func testAllLogoLinesNonEmpty() {
        for (i, line) in tokiLogoLines.enumerated() {
            XCTAssertFalse(line.isEmpty, "line \(i) is empty")
        }
    }

    func testAllLogoLinesContainAt() {
        for (i, line) in tokiLogoLines.enumerated() {
            XCTAssertTrue(line.contains("@"), "line \(i) has no @")
        }
    }

    func testBannerStringContainsKeyElements() {
        let banner = tokiBannerString
        XCTAssertTrue(banner.contains("/toki"))
        XCTAssertTrue(banner.contains("v\(appVersion)"))
        XCTAssertTrue(banner.contains("github.com/aashutoshrathi/toki"))
        XCTAssertTrue(banner.contains("@"))
    }

    func testBannerStringEndsWithNewline() {
        XCTAssertTrue(tokiBannerString.hasSuffix("\n"))
    }

}
