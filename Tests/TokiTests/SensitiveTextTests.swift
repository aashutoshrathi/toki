import XCTest
@testable import Toki

final class SensitiveTextTests: XCTestCase {
    func testRedactsEmailButKeepsSurroundingText() {
        XCTAssertEqual(SensitiveText.redactingEmails("me@example.com"), "•••••@•••••")
        // An email embedded in a subtitle: only the address is masked.
        XCTAssertEqual(
            SensitiveText.redactingEmails("OpenAI Codex - a.b+tag@work.co · Resets in 3h"),
            "OpenAI Codex - •••••@••••• · Resets in 3h"
        )
    }

    func testLeavesNonEmailTextUntouched() {
        XCTAssertEqual(SensitiveText.redactingEmails("OpenAI Codex - Plus"), "OpenAI Codex - Plus")
    }

    func testRedactedValueHidesLength() {
        // A fixed-length mask so the character count itself leaks nothing.
        XCTAssertEqual(SensitiveText.redactedValue("Acme, Inc."), "••••••")
        XCTAssertEqual(SensitiveText.redactedValue("x"), "••••••")
    }
}
