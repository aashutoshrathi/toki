import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation

@MainActor
final class RemoteControlServer: ObservableObject {
    static let shared = RemoteControlServer()
    static let hostedRemoteControlOrigin = "https://rc.toki.aashutosh.dev"

    enum HostMode: String, CaseIterable, Identifiable {
        case tailscale
        case localNetwork
        case localhost
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localhost: return "Localhost"
            case .localNetwork: return "Local network"
            case .tailscale: return "Tailscale (Recommended)"
            case .custom: return "Custom"
            }
        }
    }

    enum CompanionAppMode: String, CaseIterable, Identifiable {
        case sameHost
        case localhost
        case localNetwork
        case hosted

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sameHost: return "Same as host"
            case .localhost: return "Local"
            case .localNetwork: return "Local network"
            case .hosted: return "Toki RC (Recommended)"
            }
        }
    }

    enum SessionLifetime: Int, CaseIterable, Identifiable {
        case oneHour = 3_600
        case twelveHours = 43_200
        case oneDay = 86_400
        case twoDays = 172_800

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .oneHour: return "1 hour"
            case .twelveHours: return "12 hours (Recommended)"
            case .oneDay: return "1 day"
            case .twoDays: return "2 days"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var token: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var lastError: String?
    @Published private(set) var tailscaleDNSName: String?
    // nil until the first check completes; true when `tailscale serve` fronts our port on 443,
    // so the hosted Toki RC UI can actually reach this Mac from a phone.
    @Published private(set) var tailscaleServeReady: Bool?
    @Published private(set) var isEnablingServe = false
    @Published private(set) var serveSetupError: String?

    @Published var hostMode: HostMode = .localhost {
        didSet {
            if hostMode == .tailscale {
                refreshTailscaleStatus()
            }
        }
    }
    @Published var customHost = ""
    @Published var companionAppMode: CompanionAppMode = .sameHost
    @Published var sessionLifetime: SessionLifetime = .twelveHours

    let port = 8765

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = ""
    private var activeAgents: [ActiveAgent] = []

    private init() {
        hostMode = Self.preferredHostMode(
            tailscaleAvailable: Self.tailscaleIP() != nil,
            localNetworkAvailable: Self.localNetworkIP() != nil
        )
        refreshTailscaleStatus()
    }

    var host: String? {
        switch hostMode {
        case .localhost:
            return "localhost"
        case .localNetwork:
            return Self.localNetworkIP()
        case .tailscale:
            return tailscaleDNSName
        case .custom:
            let trimmed = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var availableHostModes: [HostMode] {
        Self.orderedHostModes(
            tailscaleAvailable: Self.tailscaleIP() != nil || tailscaleDNSName != nil
        )
    }

    static func orderedHostModes(tailscaleAvailable: Bool) -> [HostMode] {
        var modes: [HostMode] = [.localNetwork, .localhost, .custom]
        if tailscaleAvailable { modes.insert(.tailscale, at: 0) }
        return modes
    }

    static func preferredHostMode(
        tailscaleAvailable: Bool,
        localNetworkAvailable: Bool
    ) -> HostMode {
        if tailscaleAvailable { return .tailscale }
        if localNetworkAvailable { return .localNetwork }
        return .localhost
    }

    var connectURL: String? {
        guard isRunning, let token else { return nil }
        return Self.makeConnectURL(
            companionAppMode: companionAppMode,
            hostMode: hostMode,
            host: host,
            localNetworkHost: Self.localNetworkIP(),
            token: token,
            port: port
        )
    }

    static func makeConnectURL(
        companionAppMode: CompanionAppMode,
        hostMode: HostMode,
        host: String?,
        localNetworkHost: String?,
        token: String,
        port: Int
    ) -> String? {
        switch companionAppMode {
        case .sameHost:
            guard let host else { return nil }
            return directConnectURL(
                host: host,
                scheme: hostMode == .tailscale ? "https" : "http",
                port: hostMode == .tailscale ? nil : port,
                token: token
            )
        case .localhost:
            return directConnectURL(host: "localhost", scheme: "http", port: port, token: token)
        case .localNetwork:
            guard let localNetworkHost else { return nil }
            return directConnectURL(host: localNetworkHost, scheme: "http", port: port, token: token)
        case .hosted:
            guard let host, isTailscaleDNSHost(host) else { return nil }
            var parameters = URLComponents()
            parameters.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "token", value: token)
            ]

            var components = URLComponents(string: Self.hostedRemoteControlOrigin)
            components?.path = "/"
            components?.percentEncodedFragment = parameters.percentEncodedQuery
            return components?.url?.absoluteString
        }
    }

    private static func directConnectURL(
        host: String,
        scheme: String,
        port: Int?,
        token: String
    ) -> String? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url?.absoluteString
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        token = nil
        pairingCode = nil
        outputBuffer = ""

        guard let script = Bundle.main.url(forResource: "toki_remote", withExtension: "py") else {
            lastError = "The companion server script is missing from the app bundle."
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [
            "python3", "-u", script.path,
            "--port", "\(port)",
            "--session-ttl", "\(sessionLifetime.rawValue)",
            "--agent-snapshot-stdin",
            "--no-qr"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment

        let output = Pipe()
        let input = Pipe()
        task.standardInput = input
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
        inputPipe = input
        isRunning = true
        refreshTailscaleStatus()
        sendActiveAgentSnapshot()
    }

    func stop() {
        guard let task = process else { return }
        task.terminationHandler = nil
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        task.terminate()
        process = nil
        inputPipe = nil
        isRunning = false
        token = nil
        pairingCode = nil
        outputBuffer = ""
    }

    func updateActiveAgents(_ agents: [ActiveAgent]) {
        activeAgents = agents
        sendActiveAgentSnapshot()
    }

    static func remoteProviderName(for provider: Provider) -> String? {
        switch provider {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        case .openCode:
            return "opencode"
        default:
            return nil
        }
    }

    private func sendActiveAgentSnapshot() {
        guard isRunning, let inputPipe else { return }
        let agents = activeAgents.compactMap { agent -> [String: Any]? in
            guard let provider = Self.remoteProviderName(for: agent.provider) else { return nil }
            return [
                "pid": agent.processID,
                "provider": provider,
                "cwd": agent.directory.map { $0 as Any } ?? NSNull(),
                "title": agent.title,
                "tty": agent.terminalTTY.map { $0 as Any } ?? NSNull()
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["agents": agents]),
            var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    private func parseOutput(_ text: String) {
        outputBuffer += text
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            parseOutputLine(line)
        }
    }

    private func parseOutputLine(_ text: String) {
        if token == nil, let range = text.range(of: "token=") {
            let value = text[range.upperBound...].prefix {
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
            }
            if !value.isEmpty { token = String(value) }
        }
        if let range = text.range(of: "pairing_code=") {
            let value = text[range.upperBound...].prefix { $0.isNumber }
            if value.count == 6 {
                pairingCode = String(value)
            }
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        inputPipe = nil
        isRunning = false
        token = nil
        pairingCode = nil
        outputBuffer = ""
        if status != 0 {
            lastError = "The remote control server stopped (exit code \(status))."
        }
    }

    static func localNetworkIP() -> String? {
        let addresses = interfaceIPv4Addresses().filter { !isTailscaleAddress($0.ip) }
        if let en0 = addresses.first(where: { $0.name == "en0" }) { return en0.ip }
        return addresses.first?.ip
    }

    static func tailscaleIP() -> String? {
        interfaceIPv4Addresses().first { isTailscaleAddress($0.ip) }?.ip
    }

    nonisolated static func tailscaleDNSName(from statusData: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: statusData),
            let status = object as? [String: Any],
            let selfNode = status["Self"] as? [String: Any],
            let rawName = selfNode["DNSName"] as? String
        else {
            return nil
        }

        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isTailscaleDNSHost(name) else { return nil }
        return name
    }

    private nonisolated static func isTailscaleDNSHost(_ host: String) -> Bool {
        !host.isEmpty && host.lowercased().hasSuffix(".ts.net")
    }

    func refreshTailscaleStatus() {
        let checkPort = port
        Task {
            let result = await Task.detached(priority: .utility) {
                (name: Self.readTailscaleDNSName(), serve: Self.readTailscaleServeReady(port: checkPort))
            }.value
            tailscaleDNSName = result.name
            tailscaleServeReady = result.serve
        }
    }

    private nonisolated static func tailscaleExecutable() -> URL {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private nonisolated static func runTailscale(_ arguments: [String]) -> Data? {
        let executable = tailscaleExecutable()
        let task = Process()
        task.executableURL = executable
        task.arguments = executable.lastPathComponent == "env" ? ["tailscale"] + arguments : arguments

        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return data
    }

    private nonisolated static func readTailscaleDNSName() -> String? {
        guard let data = runTailscale(["status", "--json"]) else { return nil }
        return tailscaleDNSName(from: data)
    }

    private nonisolated static func readTailscaleServeReady(port: Int) -> Bool {
        guard let data = runTailscale(["serve", "status", "--json"]) else { return false }
        return serveReady(from: data, port: port)
    }

    // Run `tailscale serve` so the tailnet fronts our loopback port over HTTPS on 443. May fail if
    // the user is not the tailnet operator; the captured stderr is surfaced with a link to the guide.
    func enableTailscaleServe() {
        guard !isEnablingServe else { return }
        isEnablingServe = true
        serveSetupError = nil
        let checkPort = port
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                Self.runTailscaleServe(port: checkPort)
            }.value
            isEnablingServe = false
            if let failure {
                serveSetupError = failure
            } else {
                refreshTailscaleStatus()
            }
        }
    }

    // Returns nil on success, or an error message to surface.
    private nonisolated static func runTailscaleServe(port: Int) -> String? {
        let executable = tailscaleExecutable()
        let arguments = ["serve", "--bg", "http://127.0.0.1:\(port)"]
        let task = Process()
        task.executableURL = executable
        task.arguments = executable.lastPathComponent == "env" ? ["tailscale"] + arguments : arguments

        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardOutput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return "Couldn't run tailscale. Make sure Tailscale is installed."
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus == 0 { return nil }
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        return "tailscale serve did not start. Try running it in Terminal (see the guide)."
    }

    // `tailscale serve status --json` reports a Web handler map keyed by "<host>:<port>", each with
    // a Proxy target. Ready means a :443 handler forwards to our loopback port.
    nonisolated static func serveReady(from data: Data, port: Int) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let web = root["Web"] as? [String: Any]
        else {
            return false
        }
        let needle = "127.0.0.1:\(port)"
        for (hostPort, value) in web {
            guard
                hostPort.hasSuffix(":443"),
                let entry = value as? [String: Any],
                let handlers = entry["Handlers"] as? [String: Any]
            else {
                continue
            }
            for handler in handlers.values {
                if let handler = handler as? [String: Any],
                   let proxy = handler["Proxy"] as? String,
                   proxy.contains(needle) {
                    return true
                }
            }
        }
        return false
    }

    private static func isTailscaleAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func interfaceIPv4Addresses() -> [(name: String, ip: String)] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: interface.ifa_name), String(cString: hostBuffer)))
        }
        return result
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
