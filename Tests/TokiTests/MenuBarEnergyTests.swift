import XCTest
@testable import Toki

final class MenuBarEnergyTests: XCTestCase {
    private func inputs(
        entries: [MenuBarStatusEntry] = [
            MenuBarStatusEntry(
                provider: .codex,
                value: "42%",
                leadingText: "Codex",
                windowLabel: "5h",
                accountLabel: "work"
            )
        ],
        awaitingInput: Int = 1,
        remoteControlOn: Bool = false,
        density: MenuBarDensity = .comfortable
    ) -> MenuBarRenderInputs {
        MenuBarRenderInputs(
            entries: entries,
            awaitingInput: awaitingInput,
            remoteControlOn: remoteControlOn,
            density: density
        )
    }

    func testUnchangedCompleteRenderInputsCompareEqual() {
        XCTAssertEqual(inputs(), inputs())
    }

    func testChangedScalarRenderInputsCompareNotEqual() {
        let baseline = inputs()

        XCTAssertNotEqual(baseline, inputs(awaitingInput: 2))
        XCTAssertNotEqual(baseline, inputs(remoteControlOn: true))
        XCTAssertNotEqual(baseline, inputs(density: .compact))
    }

    func testEveryRenderedEntryFieldContributesToEquality() {
        let baseline = inputs()
        let entry = baseline.entries[0]

        let changes = [
            MenuBarStatusEntry(provider: .claudeCode, value: entry.value, leadingText: entry.leadingText,
                               windowLabel: entry.windowLabel, accountLabel: entry.accountLabel),
            MenuBarStatusEntry(provider: entry.provider, value: "43%", leadingText: entry.leadingText,
                               windowLabel: entry.windowLabel, accountLabel: entry.accountLabel),
            MenuBarStatusEntry(provider: entry.provider, value: entry.value, leadingText: "Claude",
                               windowLabel: entry.windowLabel, accountLabel: entry.accountLabel),
            MenuBarStatusEntry(provider: entry.provider, value: entry.value, leadingText: entry.leadingText,
                               windowLabel: "7d", accountLabel: entry.accountLabel),
            MenuBarStatusEntry(provider: entry.provider, value: entry.value, leadingText: entry.leadingText,
                               windowLabel: entry.windowLabel, accountLabel: "personal")
        ]

        for changedEntry in changes {
            XCTAssertNotEqual(baseline, inputs(entries: [changedEntry]))
        }
    }

    func testEntryOrderContributesToEquality() {
        let first = MenuBarStatusEntry(provider: .codex, value: "42%")
        let second = MenuBarStatusEntry(provider: .claudeCode, value: "84%")

        XCTAssertNotEqual(inputs(entries: [first, second]), inputs(entries: [second, first]))
    }
}
