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
            case .tunnel: return "Cloudflare Tunnel (public)"
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
            case .sameHost: return "Same as host (Recommended)"
            case .localhost: return "Local"
            case .localNetwork: return "Local network"
            case .hosted: return "Toki RC (hosted)"
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

    // A phone that has passed pairing. Toki learns about these over the server's stdout rather
    // than an HTTP endpoint, so one paired phone can neither enumerate the others nor revoke them.
    struct PairedDevice: Identifiable, Equatable, Decodable {
        let id: String
        let name: String
        let ip: String
        // True when `ip` is the proxy that fronted the request rather than the device itself,
        // which is what `tailscale serve` and `cloudflared` look like from here.
        let proxied: Bool
        let paired: Date
        let seen: Date
        let expires: Date

        private enum CodingKeys: String, CodingKey {
            case id, name, ip, proxied, paired, seen, expires
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            ip = try container.decode(String.self, forKey: .ip)
            proxied = try container.decode(Bool.self, forKey: .proxied)
            paired = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .paired))
            seen = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .seen))
            expires = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .expires))
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var token: String?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingCodeExpiresAt: Date?
    static let pairingCodeTTL: TimeInterval = 2 * 60
    @Published private(set) var lastError: String?
    @Published private(set) var tailscaleDNSName: String?
    @Published private(set) var serveState: ServeState?

    /// nil while unknown, which includes a status that could not be read.
    var tailscaleServeReady: Bool? {
        switch serveState {
        case .ready: return true
        case .conflict, .notServing: return false
        case .unreadable, nil: return nil
        }
    }

    var serveStatusProblem: String? {
        if case let .unreadable(reason) = serveState { return reason }
        return nil
    }
    /// True when HTTPS :443 already serves a different app, so auto-serve is suppressed.
    var tailscaleServeConflict: Bool { serveState == .conflict }
    @Published private(set) var tailscaleStatusDiagnostic: String?
    @Published private(set) var isEnablingServe = false
    @Published private(set) var serveSetupFailure: ServeSetupFailure?
    /// nil until the first status check; false means no runnable `tailscale` was found.
    @Published private(set) var tailscaleCLIAvailable: Bool?
    // Enabled once per running server, so a refusal is reported once, not retried every poll.
    private var didAttemptAutoServe = false
    /// Why Toki declined to run `tailscale serve` itself, when it did.
    @Published private(set) var autoServeSkipped: String?
    @Published private(set) var tunnelHost: String?
    @Published private(set) var isStartingTunnel = false
    @Published private(set) var tunnelError: String?

    @Published var hostMode: HostMode = .localhost {
        didSet {
            guard hostMode != oldValue else { return }
            if hostMode == .tailscale {
                refreshTailscaleStatus()
            }
            if oldValue == .tunnel {
                stopTunnel()
            }
            // The host mode decides which networks the server answers, and that is fixed when the
            // process starts. Restarting is what makes a narrowed setting take effect; leaving the
            // old process up would keep serving the wider one it was launched with. restart()
            // brings the tunnel up again too, when that is the new mode.
            if isRunning {
                restart()
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
    private var usageSnapshots: [AccountSnapshot] = []
    private var tunnelProcess: Process?

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

    // Ordered by how much they expose. A Cloudflare quick tunnel puts this Mac behind an address
    // anyone on the internet can reach, so it sits last rather than first: it is the fallback for
    // someone who cannot run Tailscale, not the shape to reach for.
    static func orderedHostModes(
        tailscaleAvailable: Bool,
        cloudflaredAvailable: Bool = false
    ) -> [HostMode] {
        var modes: [HostMode] = [.localNetwork, .localhost, .custom]
        if tailscaleAvailable { modes.insert(.tailscale, at: 0) }
        if cloudflaredAvailable { modes.append(.tunnel) }
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

    /// Relaunch so a changed setting takes effect, without racing the old process for the port.
    ///
    /// stop() only sends SIGTERM. Starting straight afterwards can bind port 8765 while the old
    /// server still holds it, and the replacement exits with EADDRINUSE, which reads to the user
    /// as Remote Control simply refusing to come back. Wait for the old process to actually go.
    func restart() {
        guard let previous = process else {
            start()
            return
        }
        stop()
        Task { @MainActor in
            await Task.detached { previous.waitUntilExit() }.value
            start()
        }
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

    // How far the server should be reachable, derived from the Host setting.
    //
    // `bind` is only the first gate and cannot express every mode on its own: with Tailscale the
    // same port has to answer `tailscale serve` over loopback and a phone at the 100.x address,
    // and one bind() covers neither pair. `access` is the peer check the server applies per
    // connection, and it is what keeps a port bound to 0.0.0.0 from being open to the coffee-shop
    // Wi-Fi the Mac also happens to be on.
    static func reach(for hostMode: HostMode) -> (bind: String, access: String) {
        switch hostMode {
        case .localhost:
            return ("127.0.0.1", "loopback")
        case .tunnel:
            // cloudflared runs on this Mac and dials 127.0.0.1, so nothing else needs the port.
            // Its own policy rather than loopback's: this is the one mode where a relay carrying
            // someone in from the public internet is the intended behaviour, not a breach of it.
            return ("127.0.0.1", "tunnel")
        case .tailscale:
            return ("0.0.0.0", "tailnet")
        case .localNetwork:
            return ("0.0.0.0", "private")
        case .custom:
            // The user named a host we can't classify, so we can't narrow this for them.
            return ("0.0.0.0", "any")
        }
    }

    // Extra Host header values to answer to. Everything Toki hands out itself (loopback, literal
    // IPs, .ts.net, .trycloudflare.com) the server already accepts; only a custom host is unknown
    // to it, and it has to be named or the anti-rebinding check would reject the user's own link.
    static func allowedHostArguments(for hostMode: HostMode, customHost: String) -> [String] {
        guard hostMode == .custom else { return [] }
        let trimmed = customHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return ["--allow-host", trimmed]
    }

    func start() {
        guard !isRunning else { return }
        lastError = nil
        token = nil
        pairingCode = nil
        pairingCodeExpiresAt = nil
        pairedDevices = []
        outputBuffer = ""

        guard let script = Self.serverScriptURL() else {
            lastError = "The companion server script is missing from the app bundle."
            return
        }

        let reach = Self.reach(for: hostMode)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [
            "python3", "-u", script.path,
            "--port", "\(port)",
            "--bind", reach.bind,
            "--access", reach.access,
            "--session-ttl", "\(sessionLifetime.rawValue)",
            "--agent-snapshot-stdin",
            "--no-qr"
        ] + Self.allowedHostArguments(for: hostMode, customHost: customHost)
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
        // A fresh server is a fresh chance to front it with HTTPS, including after a host change
        // that made Tailscale the route.
        didAttemptAutoServe = false
        serveSetupFailure = nil
        refreshTailscaleStatus()
        if hostMode == .tunnel { startTunnel() }
        sendActiveAgentSnapshot()
        sendUsageSnapshot()
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
        pairingCodeExpiresAt = nil
        pairedDevices = []
        outputBuffer = ""
    }

    func updateActiveAgents(_ agents: [ActiveAgent]) {
        activeAgents = agents
        sendActiveAgentSnapshot()
        // Ride the agent heartbeat so the phone's usage reading tracks the live pipe, not the far
        // slower usage refresh, which would otherwise read as stale between refreshes.
        sendUsageSnapshot()
    }

    func updateUsage(_ snapshots: [AccountSnapshot]) {
        usageSnapshots = snapshots
        sendUsageSnapshot()
    }

    /// The phone gets the same numbers the menu bar shows, not a second source of truth.
    nonisolated static func usagePayload(from snapshots: [AccountSnapshot]) -> [[String: Any]] {
        snapshots.map { snapshot in
            var entry: [String: Any] = [
                "id": snapshot.id,
                "name": snapshot.name,
                "provider": snapshot.provider.rawValue,
                "primary": snapshot.primary,
                "error": snapshot.isError
            ]
            // No quota API means no ratio; a placeholder would draw a bar for a number nobody has.
            if let remaining = snapshot.remainingRatio { entry["remaining"] = remaining }
            if !snapshot.subtitle.isEmpty { entry["detail"] = snapshot.subtitle }
            if let value = snapshot.menuBarValue { entry["value"] = value }
            return entry
        }
    }

    private func sendUsageSnapshot() {
        guard isRunning, let inputPipe else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["usage": Self.usagePayload(from: usageSnapshots)]),
            var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    static func remoteProviderName(for provider: Provider) -> String? {
        switch provider {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        case .openCode:
            return "opencode"
        case .fx:
            return "fx"
        case .antigravity:
            return "antigravity"
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

    nonisolated static func parseDeviceLine(_ text: String) -> [PairedDevice]? {
        guard text.hasPrefix("devices=") else { return nil }
        let payload = Data(text.dropFirst("devices=".count).utf8)
        struct Envelope: Decodable { let devices: [PairedDevice] }
        return try? JSONDecoder().decode(Envelope.self, from: payload).devices
    }

    /// End one device's session. Its next request fails auth and the phone returns to pairing.
    func revoke(_ device: PairedDevice) {
        guard isRunning, let inputPipe else { return }
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["revoke": device.id]),
            var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
        // Drop it locally too, so the row disappears on the click rather than on the next publish.
        pairedDevices.removeAll { $0.id == device.id }
    }

    private func parseOutputLine(_ text: String) {
        if let devices = Self.parseDeviceLine(text) {
            pairedDevices = devices
            return
        }
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
                pairingCodeExpiresAt = Date().addingTimeInterval(Self.pairingCodeTTL)
            }
        }
    }

    private func handleTermination(status: Int32) {
        process = nil
        inputPipe = nil
        isRunning = false
        token = nil
        pairingCode = nil
        pairingCodeExpiresAt = nil
        pairedDevices = []
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

    nonisolated static func tailscaleJSONObject(from data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] {
            return root
        }
        guard let brace = data.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data[brace...])) as? [String: Any]
    }

    nonisolated static func tailscaleDNSName(from statusData: Data) -> String? {
        guard
            let status = tailscaleJSONObject(from: statusData),
            let selfNode = status["Self"] as? [String: Any],
            let rawName = selfNode["DNSName"] as? String
        else {
            return nil
        }

        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard isTailscaleDNSHost(name) else { return nil }
        return name
    }

    nonisolated static func rawSelfDNSName(from statusData: Data) -> String? {
        guard
            let status = tailscaleJSONObject(from: statusData),
            let selfNode = status["Self"] as? [String: Any]
        else {
            return nil
        }
        return selfNode["DNSName"] as? String
    }

    nonisolated static func isTailscaleDNSHost(_ host: String) -> Bool {
        !host.isEmpty && host.lowercased().hasSuffix(".ts.net")
    }

    nonisolated static func isUsableTailscaleHost(detected: String?, manual: String) -> Bool {
        if detected != nil { return true }
        return isTailscaleDNSHost(manual.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var hasUsableTailscaleHost: Bool {
        Self.isUsableTailscaleHost(detected: tailscaleDNSName, manual: manualTailscaleHost)
    }

    func refreshTailscaleStatus() {
        let checkPort = port
        Task {
            let result = await Task.detached(priority: .utility) {
                let status = Self.readTailscaleStatus()
                let serve = Self.readTailscaleServe(port: checkPort)
                return (name: status.name, diagnostic: status.diagnostic, cli: status.cliAvailable, serve: serve)
            }.value
            tailscaleStatusDiagnostic = result.diagnostic
            tailscaleCLIAvailable = result.cli
            serveState = result.serve.state
            // When status can't read the name, serve's own config names the same host, so use it.
            tailscaleDNSName = result.name ?? result.serve.host
            enableTailscaleServeIfNeeded()
        }
    }

    // Tailscale (or hosted) needs `tailscale serve` fronting the port for HTTPS, so Toki runs it.
    // An existing :443 handler is left alone; replacing it is a decision the UI asks for explicitly.
    private func enableTailscaleServeIfNeeded() {
        guard isRunning, hostMode == .tailscale || companionAppMode == .hosted else { return }
        guard !didAttemptAutoServe else { return }
        // Only act when serve is definitively not running.
        guard tailscaleServeReady == false else { return }
        // Deliberate refusals, each explained in its own row.
        if tailscaleServeConflict {
            autoServeSkipped = "Something else already serves HTTPS on 443, so Toki left it alone."
            return
        }
        if tailscaleCLIAvailable != true {
            autoServeSkipped = "Toki has no tailscale command to run."
            return
        }
        autoServeSkipped = nil
        didAttemptAutoServe = true
        enableTailscaleServe()
    }

    private nonisolated static func tailscaleExecutable() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/usr/bin/tailscale",
            "\(home)/.local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
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
        /// Killed for taking too long. A GUI-app binary that is not a CLI hangs rather than
        /// failing, so this is one of the ways "no usable tailscale here" shows up.
        var timedOut = false

        // `launched` only says a process started, and the fallback launches `/usr/bin/env`, which
        // always exists - it then exits 127 when there is no `tailscale` for it to find. Neither
        // that nor a binary that hangs is a CLI Toki can drive.
        var foundCLI: Bool { launched && !timedOut && exitCode != 127 }
    }

    private nonisolated static func runTailscale(_ arguments: [String], timeout: TimeInterval = 6) -> TailscaleRun {
        let task = tailscaleProcess(arguments)
        // Redirect to temp files, not Pipes: a large tailnet's status JSON can exceed the pipe
        // buffer and block the child before it exits, which the timeout below would misread as a
        // hang. Files never block the writer.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("toki-ts-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("toki-ts-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try? FileHandle(forWritingTo: outURL)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle?.close()
            try? errHandle?.close()
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        task.standardOutput = outHandle ?? FileHandle.nullDevice
        task.standardError = errHandle ?? FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return TailscaleRun(data: nil, launched: false, exitCode: -1, stderr: "")
        }
        // Bound the wait so a hung `tailscale` (e.g. a GUI-app binary that doesn't act as a CLI)
        // can't block this worker forever and pile up under the periodic refresh.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate() // SIGTERM
            // Force-kill if it ignores SIGTERM, and reap it, so a hung tailscale can't survive and
            // let the periodic refresh accumulate stuck processes.
            let killDeadline = Date().addingTimeInterval(1)
            while task.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
            DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "command_timeout",
                                           detail: arguments.joined(separator: " "))
            return TailscaleRun(data: nil, launched: true, exitCode: -1,
                                stderr: "timed out after \(Int(timeout))s", timedOut: true)
        }
        try? outHandle?.close()
        try? errHandle?.close()
        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let stderr = ((try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = task.terminationStatus
        if code != 0 {
            DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "command_failed",
                                           detail: "\(arguments.joined(separator: " ")) exit=\(code) \(stderr)")
        }
        return TailscaleRun(data: code == 0 ? data : nil, launched: true, exitCode: code, stderr: stderr)
    }

    // Returns the MagicDNS name, or a short diagnostic explaining why it couldn't be read, plus
    // whether a `tailscale` CLI could be run at all - the Mac App Store build ships none, and
    // without one Toki can read nothing and enable nothing, which the UI has to say out loud.
    nonisolated static func readTailscaleStatus() -> (name: String?, diagnostic: String?, cliAvailable: Bool) {
        let run = runTailscale(["status", "--json"])
        guard let data = run.data else {
            guard run.foundCLI else {
                return (nil, "Couldn't run the tailscale command. Is Tailscale installed?", false)
            }
            let detail = run.stderr.isEmpty ? "exit code \(run.exitCode)" : run.stderr
            return (nil, "tailscale status failed: \(detail)", true)
        }
        if let name = tailscaleDNSName(from: data) {
            return (name, nil, true)
        }
        let diagnostic = statusDiagnostic(from: data)
        DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "no_dns_name",
                                       detail: "\(diagnostic) raw=\(rawSelfDNSName(from: data) ?? "<absent>")")
        return (nil, diagnostic, true)
    }

    // The command ran but yielded no usable .ts.net name, so the settings hint has to point at the
    // right fix. "MagicDNS is off" is claimed only for a running node that really reports no name;
    // every other way of failing to read one says so instead of accusing a setting that may be on.
    nonisolated static func statusDiagnostic(from data: Data) -> String {
        guard let status = tailscaleJSONObject(from: data) else {
            return "Couldn't read Tailscale's status. Enter the host by hand."
        }
        if let backend = status["BackendState"] as? String, backend != "Running" {
            return "Tailscale isn't connected (state: \(backend)). Sign in, then try again."
        }
        guard
            let selfNode = status["Self"] as? [String: Any],
            let rawName = selfNode["DNSName"] as? String
        else {
            return "Tailscale didn't report a name for this Mac. Enter the host by hand."
        }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty || !name.contains(".") {
            return "Tailscale is connected but MagicDNS is off, so there's no .ts.net name. Turn on MagicDNS, or enter the host by hand."
        }
        return "Tailscale reports this Mac as \(name), which isn't a .ts.net name. Enter the host by hand."
    }

    private nonisolated static func readTailscaleServe(port: Int) -> (state: ServeState, host: String?) {
        let run = runTailscale(["serve", "status", "--json"])
        guard run.foundCLI else {
            return (.unreadable("Toki couldn't run the tailscale command to check HTTPS."), nil)
        }
        return (serveState(from: run.data, port: port), servedTailscaleHost(from: run.data))
    }

    // Why `tailscale serve` refused, in words, plus the one command that clears it where there is
    // one. Every failure worth naming has a specific remedy; handing back raw stderr and "try
    // Terminal" leaves the user to work out which of them they hit.
    struct ServeSetupFailure: Equatable, Sendable {
        let message: String
        /// A command to run in Terminal that clears this particular refusal, when one exists.
        let remedy: String?
        /// True when the cause could not be identified, which is the only case where retrying
        /// with an older command form is worth anything.
        let isUnrecognized: Bool
    }

    // Run `tailscale serve` so the tailnet fronts our loopback port over HTTPS on 443.
    func enableTailscaleServe() {
        guard !isEnablingServe else { return }
        isEnablingServe = true
        serveSetupFailure = nil
        let checkPort = port
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                Self.runTailscaleServe(port: checkPort)
            }.value
            isEnablingServe = false
            if let failure {
                serveSetupFailure = failure
                DiagnosticLogger.shared.record(.warning, component: "tailscale", code: "serve_failed",
                                               detail: failure.message)
            } else {
                refreshTailscaleStatus()
            }
        }
    }

    /// The command Toki runs, offered for copying when it has to be run by hand.
    var tailscaleServeCommand: String {
        "tailscale serve --bg http://127.0.0.1:\(port)"
    }

    // A cert can take a while to provision on first use, so this waits far longer than a status
    // read - but never indefinitely, since the UI is waiting on it.
    // nonisolated: the server is @MainActor, so its statics are too by default, and the serve
    // runner that reads this is deliberately off the main actor.
    private nonisolated static let serveTimeout: TimeInterval = 25

    // Returns nil on success, or the failure to surface.
    private nonisolated static func runTailscaleServe(port: Int) -> ServeSetupFailure? {
        let target = "http://127.0.0.1:\(port)"
        let run = runTailscale(["serve", "--bg", target], timeout: serveTimeout)
        if run.launched, run.exitCode == 0 { return nil }

        let failure = serveFailure(launched: run.foundCLI, exitCode: run.exitCode, stderr: run.stderr)
        // Tailscale releases before 1.58 want the port spelled out. Only an unattributable failure
        // is worth a second attempt: an operator or certificate refusal refuses either form.
        guard failure.isUnrecognized else { return failure }
        let retry = runTailscale(["serve", "--bg", "443", target], timeout: serveTimeout)
        if retry.launched, retry.exitCode == 0 { return nil }
        return serveFailure(launched: retry.foundCLI, exitCode: retry.exitCode, stderr: retry.stderr)
    }

    // Pure so the mapping from Tailscale's wording to a remedy can be tested without a tailnet.
    nonisolated static func serveFailure(launched: Bool, exitCode: Int32, stderr: String) -> ServeSetupFailure {
        guard launched else {
            return ServeSetupFailure(
                message: "Toki couldn't run the tailscale command. Install Tailscale, or use the guide to set HTTPS up by hand.",
                remedy: nil,
                isUnrecognized: false
            )
        }
        let text = stderr.lowercased()
        if text.contains("timed out") {
            return ServeSetupFailure(
                message: "Enabling HTTPS timed out, which usually means Tailscale is still provisioning a certificate. Try again in a moment.",
                remedy: nil,
                isUnrecognized: false
            )
        }
        if text.contains("operator") || text.contains("access denied") || text.contains("must be run as root") {
            return ServeSetupFailure(
                message: "Tailscale only lets its operator change serve settings, and that isn't this account yet. Run this once in Terminal, then try again.",
                remedy: "sudo tailscale set --operator=$USER",
                isUnrecognized: false
            )
        }
        if text.contains("logged out") || text.contains("not logged in") || text.contains("needslogin") {
            return ServeSetupFailure(
                message: "Tailscale isn't signed in on this Mac, so it can't serve anything. Sign in, then try again.",
                remedy: "tailscale up",
                isUnrecognized: false
            )
        }
        if text.contains("cert") || text.contains("https") {
            return ServeSetupFailure(
                message: "This tailnet doesn't have HTTPS certificates enabled, so there's no certificate to serve with. Turn on HTTPS Certificates in the Tailscale admin console, then try again.",
                remedy: nil,
                isUnrecognized: false
            )
        }
        let detail = stderr.isEmpty ? "exit code \(exitCode)" : stderr
        return ServeSetupFailure(message: detail, remedy: nil, isUnrecognized: true)
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
    /// What `tailscale serve status` says about our port; unreadable is a separate answer from not-served.
    enum ServeState: Equatable, Sendable {
        case ready
        case conflict
        case notServing
        case unreadable(String)
    }

    /// Hosts that mean "this Mac" in a serve target; matching one literal spelling read a working serve as absent.
    private nonisolated static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "0.0.0.0"]

    /// True when a serve target points at this Mac on `port`, whatever scheme, path, or loopback spelling.
    nonisolated static func proxyTargetsLocalPort(_ proxy: String, port: Int) -> Bool {
        var rest = proxy.trimmingCharacters(in: .whitespaces)
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
        }
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        guard let colon = rest.lastIndex(of: ":") else { return false }
        let host = String(rest[..<colon])
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard Int(rest[rest.index(after: colon)...]) == port else { return false }
        return loopbackHosts.contains(host)
    }

    /// The port a `Web` key ("<host>:<port>") serves on; an IPv6 host has its own colons, so split on the last.
    nonisolated static func servedPort(fromWebKey key: String) -> Int? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        return Int(key[key.index(after: colon)...])
    }

    /// The `.ts.net` host `tailscale serve` reports, used when `tailscale status` can't supply the name.
    nonisolated static func servedTailscaleHost(from data: Data?) -> String? {
        guard let root = tailscaleJSONObject(from: data),
              let web = root["Web"] as? [String: Any] else { return nil }
        for key in web.keys.sorted() {
            guard let colon = key.lastIndex(of: ":") else { continue }
            let host = String(key[..<colon])
            if isTailscaleDNSHost(host) { return host }
        }
        return nil
    }

    nonisolated static func serveState(from data: Data?, port: Int) -> ServeState {
        guard let data else {
            return .unreadable("Toki couldn't read `tailscale serve status`.")
        }
        guard let root = tailscaleJSONObject(from: data) else {
            return .unreadable("Tailscale's serve status wasn't readable.")
        }
        // Valid JSON with no Web map is a real "not serving", not a read failure.
        guard let web = root["Web"] as? [String: Any] else { return .notServing }

        var sawConflict = false
        for (hostPort, value) in web {
            guard servedPort(fromWebKey: hostPort) == 443,
                  let entry = value as? [String: Any],
                  let handlers = entry["Handlers"] as? [String: Any] else { continue }
            for handler in handlers.values {
                guard let handler = handler as? [String: Any],
                      let proxy = handler["Proxy"] as? String else { continue }
                if proxyTargetsLocalPort(proxy, port: port) { return .ready }
            }
            // Something else owns the root path here; serving over it would replace it silently.
            if let rootHandler = handlers["/"] as? [String: Any] {
                let proxy = rootHandler["Proxy"] as? String
                if proxy == nil || !proxyTargetsLocalPort(proxy!, port: port) { sawConflict = true }
            }
        }
        return sawConflict ? .conflict : .notServing
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
