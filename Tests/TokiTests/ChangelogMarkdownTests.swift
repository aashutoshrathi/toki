import XCTest
@testable import Toki

// The changelog is authored as markdown and rendered in-app, so the panel used to show the
// asterisks and bracket syntax as literal text.
final class ChangelogMarkdownTests: XCTestCase {
    private func rendered(_ raw: String) -> String {
        String(inlineMarkdown(raw).characters)
    }

    func testBoldLeadInLosesItsMarkers() {
        XCTAssertEqual(
            rendered("**Sarvam Code joins usage tracking.** Toki auto-detects the CLI."),
            "Sarvam Code joins usage tracking. Toki auto-detects the CLI."
        )
    }

    func testContributorLinkRendersAsItsLabel() {
        XCTAssertEqual(
            rendered("[@thepushkarp](https://github.com/thepushkarp) contributed Sarvam Code."),
            "@thepushkarp contributed Sarvam Code."
        )
    }

    func testCodeSpanKeepsItsTextWithoutBackticks() {
        XCTAssertEqual(rendered("Sessions resolve from `~/.sarvam/sessions`."),
                       "Sessions resolve from ~/.sarvam/sessions.")
    }

    // Every entry is one line of prose; the full parser treats an item as its own document
    // and trims it, which would eat the spacing this preserves.
    func testInternalWhitespaceSurvives() {
        XCTAssertEqual(rendered("one  two"), "one  two")
    }

    // A stray unbalanced marker must not blank an entry out.
    func testMalformedMarkdownFallsBackToTheRawText() {
        XCTAssertFalse(rendered("A **dangling bold and a [link(broken").isEmpty)
    }

    func testBoldLeadIsUsedWithoutTechnicalBody() {
        XCTAssertEqual(
            changelogHeadline("**Quota reset actions are easier to find.** Full details and `technical code`."),
            "**Quota reset actions are easier to find.**"
        )
    }

    func testUnstructuredEntryRemainsReadable() {
        XCTAssertEqual(changelogHeadline("An entry without a bold headline."), "An entry without a bold headline.")
        XCTAssertEqual(changelogHeadline("**An unclosed heading"), "**An unclosed heading")
    }
}
