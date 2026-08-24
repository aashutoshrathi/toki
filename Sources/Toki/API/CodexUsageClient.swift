import Foundation

// appVersion is defined globally in the module

struct CodexUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let payload = try await CodexAppServerClient.fetch(account: account)
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

    static func fetch(account: AccountConfig) async throws -> CodexAppServerPayload {
        let binary = try await resolvedBinary()
        let responses = try call(account: account, binary: binary, requests: [
            (id: 2, method: "account/usage/read", params: "null"),
            (id: 3, method: "account/rateLimits/read", params: "null"),
            (id: 4, method: "account/read", params: #"{"refreshToken":false}"#)
        ])

        var payload = CodexAppServerPayload()
        payload.binarySource = binary
        payload.usage = responses.results[2]
        payload.rateLimits = responses.results[3]
        payload.account = responses.results[4]

        if payload.usage == nil && payload.rateLimits == nil {
            throw LocalizedErrorMessage(responses.errors.first ?? "Codex app-server did not return usage")
        }
        // A successful account/rateLimits/read always returns a rate_limits object per the
        // app-server schema (only primary/secondary within it are optional) - a missing
        // response here means the call itself failed or timed out. Surface that as an error
        // instead of silently falling back to usage's raw token count, which is exactly the
        // degraded display this fix exists to prevent.
        if payload.rateLimits == nil {
            throw LocalizedErrorMessage(responses.errors.first ?? "Codex app-server did not return rate limits")
        }
        return payload
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

    static func consumeRateLimitResetCredit(account: AccountConfig, creditID: String?) async throws -> String {
        let binary = try await resolvedBinary()
        var params: [String: Any] = ["idempotencyKey": UUID().uuidString]
        if let creditID {
            params["creditId"] = creditID
        }
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let paramsString = String(data: paramsData, encoding: .utf8) ?? "{}"

        let responses = try call(account: account, binary: binary, requests: [(id: 2, method: "account/rateLimitResetCredit/consume", params: paramsString)])
        guard let result = responses.results[2] as? [String: Any], let outcome = result["outcome"] as? String else {
            throw LocalizedErrorMessage(responses.errors.first ?? "Codex did not confirm the reset")
        }
        return outcome
    }

    // codex app-server has no per-request account parameter - it always acts on whichever
    // session CODEX_HOME points at (default ~/.codex). Deriving CODEX_HOME from the
    // account's configured codexAuthPath keeps multi-account setups scoped to the right
    // session instead of silently acting on the CLI's default one - most load-bearing for
    // consumeRateLimitResetCredit, since a reset credit is a limited resource.
    static func codexHomeDirectory(for account: AccountConfig) -> String {
        let authPath = expandedPath(account.codexAuthPath ?? "~/.codex/auth.json")
        return (authPath as NSString).deletingLastPathComponent
    }

    // Usage and rate-limit reads each round-trip to OpenAI's backend, so a fixed short
    // sleep would race them - rateLimits can lose that race while usage (often served from a
    // faster path) wins, silently degrading the display to raw tokens. Poll for every expected
    // response id instead, exiting as soon as they've all arrived (bounded by ~10.4s: a 0.4s
    // handshake plus up to 100 * 0.1s poll iterations).
    //
    // codex app-server is a single-client stdio transport: it exits as soon as it sees EOF
    // on stdin, regardless of requests still in flight. The subshell feeding stdin must
    // therefore stay alive (via a trailing sleep) for at least as long as we intend to poll,
    // or app-server tears itself down mid-round-trip and every response after initialize goes
    // missing - the app-server process itself is still killed explicitly below once we're done.
    private static func call(account: AccountConfig, binary: CodexBinary, requests: [(id: Int, method: String, params: String)]) throws -> (results: [Int: Any], errors: [String]) {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Toki","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":null}"#
        let requestLines = requests.map { #"{"jsonrpc":"2.0","id":\#($0.id),"method":"\#($0.method)","params":\#($0.params)}"# }
        let printfArgs = requestLines.map { "'\(shellEscaped($0))'" }.joined(separator: " ")
        // Grep against the whole line, not just the id substring, so a coincidental "id"
        // field nested inside a result payload (e.g. a future OpenAI response containing an
        // integer id) can't be mistaken for the JSON-RPC envelope's own id and end the poll
        // before that request's real response has actually arrived.
        let idChecks = requests.map { #"grep '"jsonrpc":"2.0"' "$__toki_out" | grep -qE '"id"[[:space:]]*:[[:space:]]*\#($0.id)[,}]'"# }.joined(separator: " && ")
        let codexHome = codexHomeDirectory(for: account)

        let command = """
        __toki_out=$(mktemp -t toki_codex); \
        ( printf '%s\\n' '\(shellEscaped(initialize))'; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(initialized))'; \
        sleep 0.2; \
        printf '%s\\n' \(printfArgs); \
        sleep 11 ) | CODEX_HOME='\(shellEscaped(codexHome))' PATH="\(path):$PATH" '\(shellEscaped(binary.executablePath))' app-server --stdio > "$__toki_out" 2>&1 & \
        __toki_pid=$!; \
        for ((__toki_i = 1; __toki_i <= 100; __toki_i++)); do \
        sleep 0.1; \
        if \(idChecks); then break; fi; \
        kill -0 $__toki_pid 2>/dev/null || break; \
        done; \
        kill $__toki_pid 2>/dev/null; \
        wait $__toki_pid 2>/dev/null; \
        cat "$__toki_out"; \
        rm -f "$__toki_out"
        """

        let output = try SecretResolver.runShell(command)
        var results: [Int: Any] = [:]
        var errors: [String] = []
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

        return (results, errors)
    }
}
