import Foundation

enum AntigravityUsageClient {
    private struct Report: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let window: String?
                        let remaining_fraction: Double?
                        let reset_time: String?
                        let disabled: Bool?
                    }

                    let name: String
                    let buckets: [Bucket]
                }

                let groups: [Group]
            }

            let name: String
            let data: Payload
        }

        let status: String
        let num_turns: Int
        let command: Command
    }

    static func snapshot(for account: AccountConfig, cancellation: CLIJSONProcess.Cancellation) throws -> AccountSnapshot {
        guard let executable = UsageFetcher.installedCLI(named: "agy") else {
            throw LocalizedErrorMessage("Install the Antigravity CLI and sign in to read its quota.")
        }
        let (workspace, baseEnvironment) = try CLIJSONProcess.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        var environment = baseEnvironment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"

        func run(_ arguments: [String], timeout: TimeInterval) throws -> Data {
            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = workspace
            process.environment = environment
            process.arguments = arguments
            let command = try CLIJSONProcess(process: process, label: "Antigravity \(arguments[0])", cancellation: cancellation)
            defer { command.close() }
            return try command.readOutput(timeout: timeout)
        }

        let version = String(decoding: try run(["--version"], timeout: 5), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Before 1.1.11 print mode can send an unrecognized slash command as a model prompt.
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              UpdateChecker.compareVersions(version, "1.1.11") != .orderedAscending else {
            throw LocalizedErrorMessage("Update the Antigravity CLI to 1.1.11 or later to read its quota.")
        }
        let data = try run(usageArguments, timeout: 20)
        guard let snapshot = Self.snapshot(for: account, data: data) else {
            throw LocalizedErrorMessage("Antigravity did not report model quotas. Check /usage in agy.")
        }
        return snapshot
    }

    // With slash commands disabled, print mode sends /usage to the model as a prompt.
    static let usageArguments = ["--settings", #"{"disableSlashCommands":false}"#, "-p", "/usage", "--output-format", "json"]

    static func snapshot(for account: AccountConfig, data: Data, now: Date = Date()) -> AccountSnapshot? {
        guard let report = try? JSONDecoder().decode(Report.self, from: data),
              report.status == "SUCCESS", report.num_turns == 0, report.command.name == "usage" else { return nil }

        var seen = Set<String>()
        var windows: [RateLimitWindow] = []
        var metrics: [MetricLine] = []
        var remainingByGroup: [String: Double] = [:]
        for group in report.command.data.groups where !group.name.isEmpty {
            for bucket in group.buckets {
                guard bucket.disabled != true, let fraction = bucket.remaining_fraction,
                      (0...1).contains(fraction) else { continue }
                let reset = resetDate(bucket.reset_time)
                guard reset.map({ $0 > now }) ?? true else { continue }
                let length: (label: String, hours: TimeInterval)
                switch bucket.window {
                case "5h": length = ("5h", 5)
                case "weekly": length = ("7d", 7 * 24)
                default: continue
                }
                let label = "\(group.name) \(length.label)"
                guard seen.insert(label).inserted else { continue }

                windows.append(RateLimitWindow(
                    label: label, percentLeft: Int((fraction * 100).rounded()),
                    resetHint: reset.map { "resets in \(resetDescription(for: $0))" },
                    resetAt: reset, duration: length.hours * 3600
                ))
                let precision = fraction.formatted(.percent.precision(.fractionLength(0...2)))
                metrics.append(MetricLine(label: label, value: "\(precision) left"))
                remainingByGroup[group.name] = min(remainingByGroup[group.name] ?? fraction, fraction)
            }
        }
        // Every window constrains its own group, and any available group can still run.
        guard let remaining = remainingByGroup.values.max() else { return nil }
        return AccountSnapshot(
            id: account.id, name: account.name, provider: .antigravity,
            primary: "\(remaining.formatted(.percent.precision(.fractionLength(0...2)))) left in best model group",
            subtitle: "Antigravity - CLI usage", remainingRatio: remaining,
            metrics: metrics, modelWindows: windows
        )
    }
}
