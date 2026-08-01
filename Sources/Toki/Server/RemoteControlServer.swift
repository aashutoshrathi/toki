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
        case tunnel
        case localNetwork
        case localhost
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .localhost: return "Localhost"
            case .localNetwork: return "Local network"
            case .tailscale: return "Tailscale (Recommended)"
            case .tunnel: return "Cloudflare Tunnel"
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
    // Why the Tailscale DNS name couldn't be read (command missing, not logged in, MagicDNS off),
    // surfaced in settings so a failed lookup explains itself instead of silently using the IP.
    @Published private(set) var tailscaleStatusDiagnostic: String?
    @Published private(set) var isEnablingServe = false
    @Published private(set) var serveSetupError: String?
    // Public HTTPS address from a Cloudflare quick tunnel, when Host is Cloudflare Tunnel.
    @Published private(set) var tunnelHost: String?
    @Published private(set) var isStartingTunnel = false
    @Published private(set) var tunnelError: String?

    @Published var hostMode: HostMode = .localhost {
        didSet {
            guard hostMode != oldValue else { return }
            didAutoEnableServe = false
            serveSetupError = nil
            if hostMode == .tailscale {
                refreshTailscaleStatus()
            }
            if oldValue == .tunnel {
                stopTunnel()
            }
            if hostMode == .tunnel, isRunning {
                startTunnel()
            }
        }
    }
    @Published var customHost = ""
    // A Tailscale DNS name typed by hand when `tailscale status` can't be read (e.g. the CLI
    // isn't installed). Persisted per device so it survives relaunches; the name is stable per Mac.
    private static let manualHostKey = "toki.remoteControl.manualTailscaleHost"
    @Published var manualTailscaleHost = UserDefaults.standard.string(forKey: manualHostKey) ?? "" {
        didSet { UserDefaults.standard.set(manualTailscaleHost, forKey: Self.manualHostKey) }
    }
    @Published var companionAppMode: CompanionAppMode = .sameHost
    @Published var sessionLifetime: SessionLifetime = .twelveHours

    let port = 8765

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputBuffer = ""
    private var activeAgents: [ActiveAgent] = []
    private var tunnelProcess: Process?
    // Guards the automatic `tailscale serve` so it's attempted once per Tailscale selection, not
    // re-run on every status refresh (and not retried in a loop after it fails).
    private var didAutoEnableServe = false

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
            if let tailscaleDNSName { return tailscaleDNSName }
            let manual = manualTailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return manual.isEmpty ? nil : manual
        case .tunnel:
            return tunnelHost
        case .custom:
            let trimmed = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    var availableHostModes: [HostMode] {
        Self.orderedHostModes(
            tailscaleAvailable: Self.tailscaleIP() != nil || tailscaleDNSName != nil,
            cloudflaredAvailable: Self.cloudflaredExecutable() != nil
        )
    }

    static func orderedHostModes(
        tailscaleAvailable: Bool,
        cloudflaredAvailable: Bool = false
    ) -> [HostMode] {
        var modes: [HostMode] = [.localNetwork, .localhost, .custom]
        if cloudflaredAvailable { modes.insert(.tunnel, at: 0) }
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
            tailscaleIP: Self.tailscaleIP(),
            token: token,
            port: port
        )
    }

    static func makeConnectURL(
        companionAppMode: CompanionAppMode,
        hostMode: HostMode,
        host: String?,
        localNetworkHost: String?,
        tailscaleIP: String? = nil,
        token: String,
        port: Int
    ) -> String? {
        switch companionAppMode {
        case .sameHost:
            if let host {
                let isHTTPSHost = hostMode == .tailscale || hostMode == .tunnel
                return directConnectURL(
                    host: host,
                    scheme: isHTTPSHost ? "https" : "http",
                    port: isHTTPSHost ? nil : port,
                    token: token
                )
            }
            if hostMode == .tailscale {
                return tailscaleDirectURL(ip: tailscaleIP, port: port, token: token)
            }
            return nil
        case .localhost:
            return directConnectURL(host: "localhost", scheme: "http", port: port, token: token)
        case .localNetwork:
            guard let localNetworkHost else { return nil }
            return directConnectURL(host: localNetworkHost, scheme: "http", port: port, token: token)
        case .hosted:
            if let host, isTailscaleDNSHost(host) {
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
            return tailscaleDirectURL(ip: tailscaleIP, port: port, token: token)
        }
    }

    // Fallback for when the MagicDNS name can't be read: the server binds 0.0.0.0, so a phone on
    // the tailnet can still reach it directly at the 100.x address over HTTP.
    private static func tailscaleDirectURL(ip: String?, port: Int, token: String) -> String? {
        guard let ip else { return nil }
        return directConnectURL(host: ip, scheme: "http", port: port, token: token)
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

    // Bundle.main holds the script in a packaged .app; `swift run` instead drops resources in an
    // SPM bundle beside the executable (same fallback SVGLogoAsset uses), so check both.
    private static func serverScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "toki_remote", withExtension: "py") { return url }
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("toki_remote.py"),
            executableDir?.appendingPathComponent("Toki_Toki.bundle/toki_remote.py")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        token = nil
        pairingCode = nil
        outputBuffer = ""

        guard let script = Self.serverScriptURL() else {
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
        if hostMode == .tunnel { startTunnel() }
        sendActiveAgentSnapshot()
    }

    func stop() {
        stopTunnel()
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
        didAutoEnableServe = false
        serveSetupError = nil
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
                "tty": agent.terminalTTY.map { $0 as Any } ?? NSNull(),
                "session": agent.sessionPath.map { $0 as Any } ?? NSNull()
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
                let status = Self.readTailscaleStatus()
                return (name: status.name, diagnostic: status.diagnostic,
                        serve: Self.readTailscaleServeReady(port: checkPort))
            }.value
            tailscaleDNSName = result.name
            tailscaleStatusDiagnostic = result.diagnostic
            tailscaleServeReady = result.serve
            maybeAutoEnableServe()
        }
    }

    // Choosing Tailscale for "from anywhere" implies wanting HTTPS reachability, so run
    // `tailscale serve` automatically once instead of making the user press a button. Only when
    // the server is up and we have a DNS name to serve; failures fall back to the manual button.
    private func maybeAutoEnableServe() {
        guard isRunning, hostMode == .tailscale, tailscaleDNSName != nil,
              tailscaleServeReady == false,
              !didAutoEnableServe, !isEnablingServe, serveSetupError == nil else { return }
        didAutoEnableServe = true
        enableTailscaleServe()
    }

    private nonisolated static func tailscaleExecutable() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/usr/bin/tailscale",
            "\(home)/.local/bin/tailscale"
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private nonisolated static func tailscaleProcess(_ arguments: [String]) -> Process {
        let executable = tailscaleExecutable()
        let task = Process()
        task.executableURL = executable
        guard executable.lastPathComponent == "env" else {
            task.arguments = arguments
            return task
        }
        // Finder-launched apps inherit a bare PATH, so the `env` fallback needs the usual CLI
        // directories spelled out to find a `tailscale` that isn't at a known path.
        task.arguments = ["tailscale"] + arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin"
        task.environment = environment
        return task
    }

    struct TailscaleRun {
        let data: Data?
        let launched: Bool
        let exitCode: Int32
        let stderr: String
    }

    private nonisolated static func runTailscale(_ arguments: [String], timeout: TimeInterval = 6) -> TailscaleRun {
        let task = tailscaleProcess(arguments)
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        do {
            try task.run()
        } catch {
            return TailscaleRun(data: nil, launched: false, exitCode: -1, stderr: "")
        }
        // Bound the wait: a hung `tailscale` (e.g. a GUI-app binary that doesn't act as a CLI) would
        // otherwise block this worker forever, and the periodic refresh would pile up more, wedging
        // the app. Read only after it exits - status output is well under the pipe buffer.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "command_timeout",
                                           detail: arguments.joined(separator: " "))
            return TailscaleRun(data: nil, launched: true, exitCode: -1, stderr: "timed out after \(Int(timeout))s")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = task.terminationStatus
        if code != 0 {
            DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "command_failed",
                                           detail: "\(arguments.joined(separator: " ")) exit=\(code) \(stderr)")
        }
        return TailscaleRun(data: code == 0 ? data : nil, launched: true, exitCode: code, stderr: stderr)
    }

    // Returns the MagicDNS name, or a short diagnostic explaining why it couldn't be read.
    nonisolated static func readTailscaleStatus() -> (name: String?, diagnostic: String?) {
        let run = runTailscale(["status", "--json"])
        guard let data = run.data else {
            if !run.launched {
                return (nil, "Couldn't run the tailscale command. Is Tailscale installed?")
            }
            let detail = run.stderr.isEmpty ? "exit code \(run.exitCode)" : run.stderr
            return (nil, "tailscale status failed: \(detail)")
        }
        if let name = tailscaleDNSName(from: data) {
            return (name, nil)
        }
        return (nil, statusDiagnostic(from: data))
    }

    // The command ran but yielded no usable .ts.net name: distinguish "not connected" from
    // "connected but MagicDNS is off" so the settings hint points at the right fix.
    nonisolated static func statusDiagnostic(from data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data)
        let status = object as? [String: Any]
        let backend = status?["BackendState"] as? String
        if let backend, backend != "Running" {
            return "Tailscale isn't connected (state: \(backend)). Sign in, then try again."
        }
        return "Tailscale is connected but MagicDNS is off, so there's no .ts.net name. Turn on MagicDNS, or enter the host by hand."
    }

    private nonisolated static func readTailscaleServeReady(port: Int) -> Bool {
        guard let data = runTailscale(["serve", "status", "--json"]).data else { return false }
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
        let task = tailscaleProcess(["serve", "--bg", "http://127.0.0.1:\(port)"])

        // Capture stderr to a temp file, not a Pipe. `serve --bg` can leave a descriptor open,
        // and a blocking pipe read would then never reach EOF (hangs the caller forever).
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-serve-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        defer {
            try? logHandle?.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        task.standardError = logHandle ?? FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return "Couldn't run tailscale. Make sure Tailscale is installed."
        }

        // Never block the UI indefinitely: `tailscale serve` can stall while provisioning a cert.
        let deadline = Date().addingTimeInterval(25)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if task.isRunning {
            task.terminate()
            return "Enabling HTTPS timed out. Make sure Tailscale is running and HTTPS Certificates are enabled, or run the command in Terminal (see the guide)."
        }

        try? logHandle?.close()
        if task.terminationStatus == 0 { return nil }
        let message = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }
        return "tailscale serve did not start. Try running it in Terminal (see the guide)."
    }

    // A Cloudflare quick tunnel gives this Mac a public HTTPS address with no account or DNS setup;
    // the tunnel proxies to the same server, so the phone hits one origin (no mixed content, no CORS).
    static func cloudflaredExecutable() -> URL? {
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated static func parseTunnelHost(from text: String) -> String? {
        guard let range = text.range(
            of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
            options: .regularExpression
        ) else {
            return nil
        }
        return URL(string: String(text[range]))?.host
    }

    func startTunnel() {
        guard tunnelProcess == nil else { return }
        guard let executable = Self.cloudflaredExecutable() else {
            tunnelError = "cloudflared isn't installed. Install it with `brew install cloudflared`, then reopen this menu."
            return
        }
        tunnelError = nil
        tunnelHost = nil
        isStartingTunnel = true

        let task = Process()
        task.executableURL = executable
        task.arguments = ["tunnel", "--url", "http://127.0.0.1:\(port)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8),
                  let host = Self.parseTunnelHost(from: text) else { return }
            Task { @MainActor in
                guard RemoteControlServer.shared.tunnelHost == nil else { return }
                RemoteControlServer.shared.tunnelHost = host
                RemoteControlServer.shared.isStartingTunnel = false
            }
        }
        task.terminationHandler = { _ in
            Task { @MainActor in
                let server = RemoteControlServer.shared
                server.tunnelProcess = nil
                if server.tunnelHost == nil, server.hostMode == .tunnel, server.tunnelError == nil {
                    server.tunnelError = "The Cloudflare tunnel stopped before it was ready."
                }
                server.tunnelHost = nil
                server.isStartingTunnel = false
            }
        }
        do {
            try task.run()
        } catch {
            isStartingTunnel = false
            tunnelError = "Couldn't launch cloudflared."
            return
        }
        tunnelProcess = task
    }

    func stopTunnel() {
        isStartingTunnel = false
        tunnelHost = nil
        guard let task = tunnelProcess else { return }
        task.terminationHandler = nil
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        task.terminate()
        tunnelProcess = nil
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
