import Foundation
import XCTest
@testable import Toki

final class CodexResetCreditExpiryTests: XCTestCase {
    // MARK: - CodexRateLimits parsing

    func testCreditExpiryParsedFromCreditsArray() {
        let expirySeconds = Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [
                    [
                        "id": "credit-1",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": expirySeconds,
                        "title": "Full reset (Monthly)",
                        "description": nil
                    ]
                ]
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        XCTAssertEqual(parsed.resetCreditsAvailable, 1)
        XCTAssertEqual(parsed.resetCreditExpiry?.timeIntervalSince1970 ?? 0, expirySeconds, accuracy: 1)
    }

    func testCreditExpiryNullMeansNoExpiry() {
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [
                    [
                        "id": "credit-1",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": NSNull(),
                        "title": nil,
                        "description": nil
                    ]
                ]
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        XCTAssertEqual(parsed.resetCreditsAvailable, 1)
        XCTAssertNil(parsed.resetCreditExpiry)
    }

    func testCreditExpiryAbsentWhenOnlyCountKnown() {
        // The backend may return only availableCount without the credits detail array.
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 2
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        XCTAssertEqual(parsed.resetCreditsAvailable, 2)
        XCTAssertNil(parsed.resetCreditExpiry)
    }

    func testSoonestExpiryWinsAcrossMultipleCredits() {
        let soon = Date().addingTimeInterval(2 * 3600).timeIntervalSince1970
        let later = Date().addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [
                    [
                        "id": "credit-weekly",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": later,
                        "title": "Full reset (Weekly)",
                        "description": nil
                    ],
                    [
                        "id": "credit-monthly",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": soon,
                        "title": "Full reset (Monthly)",
                        "description": nil
                    ]
                ]
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        XCTAssertEqual(parsed.resetCreditsAvailable, 2)
        XCTAssertEqual(parsed.resetCreditExpiry?.timeIntervalSince1970 ?? 0, soon, accuracy: 1)
    }

    func testNoCreditsMeansNoExpiryOrMetric() {
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 0,
                "credits": []
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        XCTAssertEqual(parsed.resetCreditsAvailable, 0)
        XCTAssertNil(parsed.resetCreditExpiry)
        XCTAssertFalse(parsed.metrics.contains(where: { $0.label == "Resets" }))
    }

    // MARK: - Metric line includes expiry

    func testResetsMetricIncludesExpiryWhenAvailable() {
        let expirySeconds = Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [
                    [
                        "id": "credit-1",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": expirySeconds,
                        "title": nil,
                        "description": nil
                    ]
                ]
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        let resetsMetric = parsed.metrics.first(where: { $0.label == "Resets" })
        XCTAssertNotNil(resetsMetric)
        XCTAssertTrue(resetsMetric?.value.hasPrefix("1 available · expires ") ?? false)
    }

    func testResetsMetricOmitsExpiryWhenNull() {
        let rateLimits: [String: Any] = [
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [
                    [
                        "id": "credit-1",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": NSNull(),
                        "title": nil,
                        "description": nil
                    ]
                ]
            ]
        ]

        let parsed = CodexRateLimits(json: rateLimits)

        let resetsMetric = parsed.metrics.first(where: { $0.label == "Resets" })
        XCTAssertNotNil(resetsMetric)
        XCTAssertEqual(resetsMetric?.value, "1 available")
    }

    // MARK: - End-to-end through CodexUsageClient.snapshot

    func testSnapshotCarriesExpiryThroughToAccountSnapshot() throws {
        let expirySeconds = Date().addingTimeInterval(5 * 24 * 3600).timeIntervalSince1970
        let account = AccountConfig(id: "codex", name: "Codex", provider: .codex)
        var payload = CodexAppServerPayload()
        payload.rateLimits = [
            "rateLimits": [
                "primary": ["usedPercent": 25.0, "windowDurationMins": 300.0]
            ],
            "rateLimitResetCredits": [
                "availableCount": 1,
                "credits": [
                    [
                        "id": "credit-1",
                        "resetType": "codexRateLimits",
                        "status": "available",
                        "grantedAt": Date().addingTimeInterval(-86400).timeIntervalSince1970,
                        "expiresAt": expirySeconds,
                        "title": nil,
                        "description": nil
                    ]
                ]
            ]
        ]

        let snapshot = try CodexUsageClient(account: account).snapshot(from: payload)

        XCTAssertEqual(snapshot.resetCreditsAvailable, 1)
        XCTAssertEqual(snapshot.resetCreditExpiry?.timeIntervalSince1970 ?? 0, expirySeconds, accuracy: 1)
    }
}
