import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation

@MainActor
final class RemoteControlServer: ObservableObject {
    static let shared = RemoteControlServer()

    enum HostMode: String, CaseIterable, Identifiable {
        case localhost
        case localNetwork
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localhost: return "Localhost"
            case .localNetwork: return "Local network"
            case .custom: return "Custom"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var token: String?
    @Published private(set) var lastError: String?

    @Published var hostMode: HostMode = .localhost
    @Published var customHost = ""

    let port = 8765

    private var process: Process?

    private init() {}

    var host: String? {
        switch hostMode {
        case .localhost:
            return "localhost"
        case .localNetwork:
            return Self.localNetworkIP()
        case .custom:
            let trimmed = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var connectURL: String? {
        guard isRunning, let token, let host else { return nil }
        return "http://\(host):\(port)/?token=\(token)"
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        token = nil

        guard let script = Bundle.main.url(forResource: "toki_remote", withExtension: "py") else {
            lastError = "The companion server script is missing from the app bundle."
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", "-u", script.path, "--port", "\(port)", "--no-qr"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.parseOutput(text) }
        }
        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.handleTermination(status: status) }
        }

        do {
            try task.run()
        } catch {
            lastError = "Could not launch Python 3. Install it (xcode-select --install) and try again."
            return
        }

        process = task
        isRunning = true
    }

    func stop() {
        guard let task = process else { return }
        task.terminationHandler = nil
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        task.terminate()
        process = nil
        isRunning = false
        token = nil
    }

    private func parseOutput(_ text: String) {
        guard token == nil, let range = text.range(of: "token=") else { return }
        let value = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        if !value.isEmpty { token = String(value) }
    }

    private func handleTermination(status: Int32) {
        process = nil
        isRunning = false
        token = nil
        if status != 0 {
            lastError = "The remote control server stopped (exit code \(status))."
        }
    }

    static func localNetworkIP() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostBuffer)
            let name = String(cString: interface.ifa_name)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    static func qrImage(for string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
