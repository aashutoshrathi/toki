import XCTest
@testable import Toki

final class ProviderScanDispositionTests: XCTestCase {
    func testFreshLocalOnlyDetectionActivatesTransientUsage() {
        XCTAssertEqual(
            providerScanDisposition(
                detected: [local(.pi)],
                snapshotProviders: [],
                configIsNil: true,
                needsOnboarding: true
            ),
            .activateLocalUsage
        )
    }

    func testConnectableDetectionStillTakesPersistencePath() {
        XCTAssertEqual(
            providerScanDisposition(
                detected: [local(.pi), connectable(.codex)],
                snapshotProviders: [],
                configIsNil: true,
                needsOnboarding: true
            ),
            .persistConnectable
        )
    }

    func testCorruptConfigCannotActivateTransientUsage() {
        XCTAssertEqual(
            providerScanDisposition(
                detected: [local(.openCode)],
                snapshotProviders: [],
                configIsNil: true,
                needsOnboarding: false
            ),
            .noAction
        )
    }

    func testAlreadySurfacedOrConfiguredLocalProviderDoesNothing() {
        XCTAssertEqual(
            providerScanDisposition(
                detected: [local(.pi)],
                snapshotProviders: [.pi],
                configIsNil: true,
                needsOnboarding: true
            ),
            .noAction
        )
        XCTAssertEqual(
            providerScanDisposition(
                detected: [local(.pi)],
                snapshotProviders: [],
                configIsNil: false,
                needsOnboarding: true
            ),
            .noAction
        )
    }

    private func local(_ provider: Provider) -> DetectedProvider {
        DetectedProvider(provider: provider, title: provider.displayName, detail: "local", makeAccount: nil)
    }

    private func connectable(_ provider: Provider) -> DetectedProvider {
        DetectedProvider(provider: provider, title: provider.displayName, detail: "account") {
            AccountConfig(id: provider.rawValue, name: provider.displayName, provider: provider)
        }
    }
}
