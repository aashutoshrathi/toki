import Foundation

// appVersion is defined globally in the module

struct CodexUsageClient {
    let account: AccountConfig

    func snapshot() async throws -> AccountSnapshot {
        let credentials = try CodexCredentialReader.readCredentials(account: account)
        let payload = try CodexAppServerClient.fetch()
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
            subtitle: rateLimits.subtitle ?? credentials.email ?? "OpenAI Codex usage",
            remainingRatio: rateLimits.remainingRatio,
            progressRatio: rateLimits.progressRatio,
            metrics: rateLimits.metrics + usage.metrics,
            accountInfo: CodexCredentialReader.accountInfo(from: credentials) + CodexAccountInfo.lines(from: payload.account)
        )
    }
}

enum CodexAppServerClient {
    static func fetch() throws -> CodexAppServerPayload {
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Toki","version":"\#(appVersion)"},"capabilities":{"experimentalApi":true}}}"#
        let initialized = #"{"jsonrpc":"2.0","method":"initialized","params":null}"#
        let usage = #"{"jsonrpc":"2.0","id":2,"method":"account/usage/read","params":null}"#
        let rateLimits = #"{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":null}"#
        let account = #"{"jsonrpc":"2.0","id":4,"method":"account/read","params":{}}"#
        let path = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        let command = """
        ( printf '%s\\n' '\(shellEscaped(initialize))'; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(initialized))'; \
        sleep 0.2; \
        printf '%s\\n' '\(shellEscaped(usage))' '\(shellEscaped(rateLimits))' '\(shellEscaped(account))'; \
        sleep 5 ) | PATH="\(path)" codex app-server --stdio
        """

        let output = try SecretResolver.runShell(command)
        var payload = CodexAppServerPayload()
        var errors: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? Int else {
                continue
            }

            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Codex app-server request \(id) failed"
                errors.append(message)
                continue
            }

            guard let result = json["result"] else { continue }
            switch id {
            case 2:
                payload.usage = result
            case 3:
                payload.rateLimits = result
            case 4:
                payload.account = result
            default:
                continue
            }
        }

        if payload.usage == nil && payload.rateLimits == nil {
            throw LocalizedErrorMessage(errors.first ?? "Codex app-server did not return usage")
        }
        return payload
    }
}
