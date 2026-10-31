import Foundation

// appVersion is defined globally in the module

struct CodexUsageClient {
    let account: AccountConfig

    func snapshot(allowsAuthRecovery: Bool = false) async throws -> AccountSnapshot {
        let payload = try await CodexAppServerClient.fetch(account: account, allowsAuthRecovery: allowsAuthRecovery)
        return try snapshot(from: payload)
    }

    // Authentication belongs to the selected Codex process. A file preflight here would reject
    // valid `keyring` and `auto` sessions before app-server gets the chance to resolve them, and
    // would make Toki handle an access token it never needs to see.
    func snapshot(from payload: CodexAppServerPayload) throws -> AccountSnapshot {
        let usage = CodexUsage(json: payload.usage ?? [:])
        let rateLimits = CodexRateLimits(json: payload.rateLimits ?? [:])
        guard usage.hasUsage || rateLimits.hasUsage else {
            throw LocalizedErrorMessage("Codex usage unavailable")
        }

        let primary: String
        if let rateLimitPrimary = rateLimits.primary {
            primary = rateLimitPrimary
        } else if let todayTokens = usage.todayTokens {
            primary = "\(formatCompact(todayTokens)) tokens today"
        } else if let lifetimeTokens = usage.summaryMetric("lifetime_tokens", "lifetimeTokens") {
            primary = "\(formatCompact(lifetimeTokens)) lifetime tokens"
        } else {
            primary = "Usage available"
        }

        return AccountSnapshot(
            id: account.id,
            name: account.name,
            provider: .codex,
            primary: primary,
            subtitle: rateLimits.subtitle ?? CodexAccountInfo.email(from: payload.account) ?? "OpenAI Codex usage",
            remainingRatio: rateLimits.remainingRatio,
            progressRatio: rateLimits.progressRatio,
            resetCreditsAvailable: rateLimits.resetCreditsAvailable,
            resetCreditExpiry: rateLimits.resetCreditExpiry,
            metrics: rateLimits.metrics + usage.metrics,
            accountInfo: CodexAccountInfo.lines(from: payload.account)
                + Self.binaryInfoLines(payload.binarySource),
            primaryWindow: rateLimits.primaryWindow,
            secondaryWindow: rateLimits.secondaryWindow
        )
    }

    private static func binaryInfoLines(_ binary: CodexBinary?) -> [MetricLine] {
        guard let binary else { return [] }
        return [MetricLine(label: "Codex CLI", value: binary.displayName)]
    }
}

enum CodexAppServerClient {
    private static let path = agentCommandSearchPath
    private final class RecoveryState: @unchecked Sendable {
        let lock = NSLock()
        var lastAttempt = Date.distantPast
        var lastRefreshCallCompleted = false
    }
    private static let statesLock = NSLock()
    nonisolated(unsafe) private static var recoveryStates: [String: RecoveryState] = [:]

    private static func recoveryState(for home: String) -> RecoveryState {
        statesLock.lock()
        defer { statesLock.unlock() }
        let key = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        if let state = recoveryStates[key] { return state }
        let state = RecoveryState()
        recoveryStates[key] = state
        return state
    }

    // Resolve once per fetch/reset and thread the result through, so the optional account-info line
    // can't disagree with the fetch if install state changes mid-refresh. Nothing usable found is a
    // real error thrown before anything is spawned, naming both fixes.
    private static func resolvedBinary() async throws -> CodexBinary {
        guard let binary = try await CodexBinaryResolver.resolve() else {
            throw LocalizedErrorMessage(CodexBinaryResolver.notFoundMessage)
        }
        DiagnosticLogger.shared.record(
            .info,
            component: "usage",
            code: "codex_binary_source",
            detail: "source=\(binary.sourceTag) executable=\(binary.executablePath)"
        )
        return binary
    }

    typealias Transport = (AccountConfig, CodexBinary, [(id: Int, method: String, params: String)], Int, Int) throws -> (results: [Int: Any], errors: [String], rpcErrors: [Int: [String: Any]])

    static func fetch(account: AccountConfig, allowsAuthRecovery: Bool = false) async throws -> CodexAppServerPayload {
        let binary = try await resolvedBinary()
        return try fetch(account: account, binary: binary, allowsAuthRecovery: allowsAuthRecovery) { account, binary, requests, pollSeconds, timeoutSeconds in
            try call(account: account, binary: binary, requests: requests, pollSeconds: pollSeconds, timeoutSeconds: timeoutSeconds)
        }
    }

    static func fetch(account: AccountConfig, binary: CodexBinary, allowsAuthRecovery: Bool, transport: Transport) throws -> CodexAppServerPayload {
        let requests = [
            (id: 2, method: "account/usage/read", params: "null"),
            (id: 3, method: "account/rateLimits/read", params: "null"),
            (id: 4, method: "account/read", params: #"{"refreshToken":false}"#)
        ]
        var responses = try transport(account, binary, requests, 10, 20)
        if allowsAuthRecovery,
           let error = responses.rpcErrors[3],
           isBackendUnauthorized(error),
           let signedIn = responses.results[4] as? [String: Any],
           let accountInfo = signedIn["account"] as? [String: Any],
           accountInfo["type"] as? String == "chatgpt" {
            let state = recoveryState(for: codexHomeDirectory(for: account))
            try state.lock.withLock {
                guard Date().timeIntervalSince(state.lastAttempt) >= 60 else {
                    guard state.lastRefreshCallCompleted else {
                        throw LocalizedErrorMessage("Codex account check failed recently. Open Codex to sign in, then try again later.")
                    }
                    return
                }
                state.lastAttempt = Date()
                state.lastRefreshCallCompleted = false
                let refreshed: (results: [Int: Any], errors: [String], rpcErrors: [Int: [String: Any]])
                do {
                    refreshed = try transport(account, binary, [(id: 2, method: "account/read", params: #"{"refreshToken":true}"#)], 30, 30)
                } catch {
                    throw LocalizedErrorMessage("Codex couldn't complete its account check. Open Codex and try again.")
                }
                guard refreshed.rpcErrors[2] == nil,
                      let result = refreshed.results[2] as? [String: Any],
                      let renewedAccount = result["account"] as? [String: Any],
                      renewedAccount["type"] as? String == "chatgpt" else {
                    throw LocalizedErrorMessage("Codex didn't return a signed-in account. Open Codex and try again.")
                }
                state.lastRefreshCallCompleted = true
            }
            responses = try transport(account, binary, requests, 10, 20)
        }

        var payload = CodexAppServerPayload()
        payload.binarySource = binary
        payload.usage = responses.results[2]
        payload.rateLimits = responses.results[3]
        payload.account = responses.results[4]

        // A successful account/rateLimits/read always returns a rate_limits object per the
        // app-server schema (only primary/secondary within it are optional) - a missing
        // response here means the call itself failed or timed out. Surface that as an error
        // instead of silently falling back to usage's raw token count, which is exactly the
        // degraded display this fix exists to prevent.
        if payload.rateLimits == nil {
            if let error = responses.rpcErrors[3] {
                let message = error["message"] as? String ?? "Codex rate limits unavailable"
                if error["code"] as? Int == -32600,
                   message == "codex account authentication required to read rate limits" {
                    throw LocalizedErrorMessage("Codex is signed out. Open Codex to sign in.")
                }
                let code = (error["code"] as? Int).map { " (RPC \($0))" } ?? ""
                throw LocalizedErrorMessage("Codex rate limits: \(message)\(code)")
            }
            throw LocalizedErrorMessage(responses.errors.first ?? "Codex app-server did not return rate limits")
        }
        return payload
    }

    static func isBackendUnauthorized(_ error: [String: Any]) -> Bool {
        guard error["code"] as? Int == -32603,
              let message = error["message"] as? String,
              message.hasPrefix("failed to fetch codex rate limits: GET "),
              message.contains("/backend-api/wham/usage failed: 401 Unauthorized") else { return false }
        return true
    }

    // Provider discovery must ask Codex whether its selected credential store is signed in.
    // Looking for auth.json cannot distinguish a missing login from a valid macOS Keychain login.
    static func readAccount(account: AccountConfig) async throws -> Any {
        let binary = try await resolvedBinary()
        let responses = try call(
            account: account,
            binary: binary,
            requests: [(id: 2, method: "account/read", params: #"{"refreshToken":false}"#)]
        )
        guard let account = responses.results[2] else {
            throw LocalizedErrorMessage(responses.errors.first ?? "Codex app-server did not return an account")
        }
        return account
    }

    private static func consumeRequest(
        account: AccountConfig,
        creditID: String?,
        condition: AutoRedeemCondition?
    ) async throws -> (binary: CodexBinary, request: (id: Int, method: String, params: String), creditExpiry: Date?) {
        let binary = try await resolvedBinary()
        let check = try call(account: account, binary: binary, requests: [(id: 2, method: "account/rateLimits/read", params: "null")])
        guard let rateLimits = check.results[2] else {
            throw LocalizedErrorMessage(check.errors.first ?? "Couldn't confirm a Codex reset is available, so none was redeemed.")
        }
        let live = CodexRateLimits(json: rateLimits)
        guard live.resetCreditsAvailable > 0 else {
            throw LocalizedErrorMessage("Codex reports no reset available right now, so none was redeemed.")
        }
        if let condition,
           !autoRedeemConditionHolds(
               condition,
               weeklyWindow: weeklyQuotaWindow(among: [live.primaryWindow, live.secondaryWindow].compactMap { $0 }),
               soonestExpiry: live.resetCreditExpiry,
               now: Date()
           ) {
            throw LocalizedErrorMessage("The auto-redeem trigger no longer holds on live data, so no reset was redeemed.")
        }
        var params: [String: Any] = ["idempotencyKey": UUID().uuidString]
        if let creditID = creditID ?? live.soonestExpiringCreditID {
            params["creditId"] = creditID
        }
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsString = String(data: paramsData, encoding: .utf8) ?? "{}"
        let request = (id: 2, method: "account/rateLimitResetCredit/consume", params: paramsString)
        let creditExpiry = creditID == nil ? live.resetCreditExpiry : nil
        return (binary, request, creditExpiry)
    }

    static func consumeRateLimitResetCredit(account: AccountConfig, creditID: String?, condition: AutoRedeemCondition?) async throws -> RedeemedReset {
        let binary: CodexBinary
        let request: (id: Int, method: String, params: String)
        let creditExpiry: Date?
        do {
            (binary, request, creditExpiry) = try await consumeRequest(account: account, creditID: creditID, condition: condition)
        } catch {
            throw ResetNotAttempted(reason: error.localizedDescription)
        }

        var lastError: String?
        for attempt in 1...consumeAttempts {
            do {
                let responses = try call(account: account, binary: binary, requests: [request], pollSeconds: consumePollSeconds)
                if let result = responses.results[2] as? [String: Any], let outcome = result["outcome"] as? String {
                    return RedeemedReset(outcome: outcome, creditExpiry: creditExpiry)
                }
                lastError = responses.errors.first
            } catch {
                lastError = error.localizedDescription
            }
            DiagnosticLogger.shared.record(
                .error,
                component: "reset",
                code: "codex_consume_unconfirmed",
                detail: "attempt=\(attempt) error=\(lastError ?? "no response")"
            )
        }
        throw LocalizedErrorMessage("Codex did not confirm the reset. It may still have been redeemed, so Toki is reading your usage again before you retry.")
    }

    private static let consumeAttempts = 2
    private static let consumePollSeconds = 45

    // codex app-server has no per-request account parameter - it always acts on whichever
    // session CODEX_HOME points at (default ~/.codex). Deriving CODEX_HOME from the
    // account's configured codexAuthPath keeps multi-account setups scoped to the right
    // session instead of silently acting on the CLI's default one - most load-bearing for
    // consumeRateLimitResetCredit, since a reset credit is a limited resource.
    static func codexHomeDirectory(for account: AccountConfig) -> String {
        let authPath = expandedPath(account.codexAuthPath ?? "~/.codex/auth.json")
        return (authPath as NSString).deletingLastPathComponent
    }

    // A symlinked home, or a path that differs only in case on APFS, is still the same login.
    static func sameHome(_ first: AccountConfig, _ second: AccountConfig) -> Bool {
        let homes = [first, second].map { codexHomeDirectory(for: $0) }
        guard homes[0] != homes[1] else { return true }
        let identifiers = homes.map {
            try? URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        }
        guard let firstIdentifier = identifiers[0], let secondIdentifier = identifiers[1] else { return false }
        return firstIdentifier.isEqual(secondIdentifier)
    }

    // Usage and rate-limit reads each round-trip to OpenAI's backend, so a fixed short
    // sleep would race them - rateLimits can lose that race while usage (often served from a
    // faster path) wins, silently degrading the display to raw tokens. Poll for every expected
    // response id instead, exiting as soon as they've all arrived (bounded by a 0.4s handshake
    // plus `pollSeconds`). A reset gets a much longer budget than a read: killing app-server while
    // the consume is in flight can still spend the credit on OpenAI's side.
    //
    // Keep stdin open until all replies arrive: app-server exits on EOF even with requests
    // in flight. Holding the FIFO open avoids a sleeping feeder delaying pipeline cleanup.
    private static func call(
        account: AccountConfig,
        binary: CodexBinary,
        requests: [(id: Int, method: String, params: String)],
        pollSeconds: Int = 10,
        timeoutSeconds: Int? = nil
    ) throws -> (results: [Int: Any], errors: [String], rpcErrors: [Int: [String: Any]]) {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Toki","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":null}"#
        let requestLines = requests.map { #"{"jsonrpc":"2.0","id":\#($0.id),"method":"\#($0.method)","params":\#($0.params)}"# }
        let printfArgs = requestLines.map { "'\(shellEscaped($0))'" }.joined(separator: " ")
        // Anchor the envelope id to the line start so an "id" nested in a result payload can't end
        // the poll early. app-server 0.165 omits "jsonrpc" from replies, so it is optional.
        let idChecks = requests.map { #"grep -qE '^\{("jsonrpc":"2.0",)?"id":\#($0.id)[,}]' "$__toki_out""# }.joined(separator: " && ")
        let codexHome = codexHomeDirectory(for: account)

        let command = """
        __toki_out=$(mktemp -t toki_codex) || exit 1; \
        __toki_pid=''; \
        trap '[[ -n "$__toki_pid" ]] && kill $__toki_pid 2>/dev/null; rm -f "$__toki_out" "$__toki_out.in"' EXIT; \
        trap 'exit 1' TERM INT; \
        mkfifo -m 600 "$__toki_out.in" || exit 1; \
        exec {__toki_input}<> "$__toki_out.in" || exit 1; \
        CODEX_HOME='\(shellEscaped(codexHome))' PATH="\(path):$PATH" '\(shellEscaped(binary.executablePath))' app-server --stdio < "$__toki_out.in" > "$__toki_out" 2>&1 & \
        __toki_pid=$!; \
        printf '%s\\n' '\(shellEscaped(initialize))' >&$__toki_input; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(initialized))' >&$__toki_input; \
        sleep 0.2; \
        printf '%s\\n' \(printfArgs) >&$__toki_input; \
        for ((__toki_i = 1; __toki_i <= \(pollSeconds * 10); __toki_i++)); do \
        sleep 0.1; \
        if \(idChecks); then break; fi; \
        kill -0 $__toki_pid 2>/dev/null || break; \
        done; \
        kill $__toki_pid 2>/dev/null; \
        wait $__toki_pid 2>/dev/null; \
        __toki_pid=''; \
        exec {__toki_input}>&-; \
        cat "$__toki_out"
        """

        let output = try SecretResolver.runShell(command, timeout: TimeInterval(timeoutSeconds ?? pollSeconds * 2))
        var results: [Int: Any] = [:]
        var errors: [String] = []
        var rpcErrors: [Int: [String: Any]] = [:]
        var unparsedLines: [String] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int else {
                unparsedLines.append(line)
                continue
            }

            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Codex app-server request \(id) failed"
                errors.append(message)
                rpcErrors[id] = error
                continue
            }

            if let result = json["result"], !(result is NSNull) {
                results[id] = result
            }
        }

        // No structured JSON-RPC error and no results usually means the selected codex itself
        // failed before speaking JSON-RPC (permission error, crash, app-server won't start) -
        // surface a sanitized snippet instead of the raw line (which could contain paths or system
        // info), prefixed with which source was selected so a corrupt app-bundled binary is
        // distinguishable from a broken PATH install.
        if errors.isEmpty, results.isEmpty, let firstUnparsed = unparsedLines.first {
            let source: String
            switch binary {
            case .pathInstall(let path): source = "Codex CLI at \(path)"
            case .appBundle: source = "Codex.app's bundled CLI"
            }
            errors.append("\(source) failed: \(firstUnparsed.prefix(200))")
        }

        return (results, errors, rpcErrors)
    }
}
