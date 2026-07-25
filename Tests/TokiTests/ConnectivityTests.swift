import Foundation
import XCTest
@testable import Toki

final class ConnectivityTests: XCTestCase {
    func testURLErrorIsRecognizedAsConnectivityFailure() {
        XCTAssertTrue(isConnectivityFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(isConnectivityFailure(URLError(.networkConnectionLost)))
        XCTAssertTrue(isConnectivityFailure(URLError(.timedOut)))
    }

    func testCancelledRequestIsNotTreatedAsConnectivityFailure() {
        XCTAssertFalse(isConnectivityFailure(URLError(.cancelled)))
    }

    func testUnrelatedErrorIsNotTreatedAsConnectivityFailure() {
        XCTAssertFalse(isConnectivityFailure(CocoaError(.fileNoSuchFile)))
    }

    func testCommandLineNetworkFailureIsRecognized() {
        let error = NSError(
            domain: "CLI",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "curl: (6) Could not resolve host: example.com"]
        )
        XCTAssertTrue(isConnectivityFailure(error))
    }
}
