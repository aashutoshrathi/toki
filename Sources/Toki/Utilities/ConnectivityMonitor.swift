import Foundation
import Network

final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "local.toki.connectivity", qos: .utility)

    func start(handler: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

func isConnectivityFailure(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return nsError.code != URLError.cancelled.rawValue
    }

    let description = error.localizedDescription.lowercased()
    return [
        "not connected to the internet",
        "network connection was lost",
        "internet connection appears to be offline",
        "could not resolve host",
        "couldn't resolve host",
        "network is unreachable",
        "no route to host"
    ].contains { description.contains($0) }
}
