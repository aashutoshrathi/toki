import Foundation

/// Routes in-app updates through Homebrew when a cask installed this copy of Toki.
///
/// The updater's DMG swap replaces the bundle in place, which desyncs brew's receipt from
/// the app on disk; a later `brew upgrade` then clobbers the newer build.
struct BrewCaskInstall: Equatable, Sendable {
    let cask: String
    let brewPrefix: String

    var brewBinary: String { brewPrefix + "/bin/brew" }
}

/// A finished `brew` invocation. `status` is nil when brew could not be launched at all.
struct BrewCaskResult: Equatable, Sendable {
    let status: Int32?
    let output: String

    var succeeded: Bool { status == 0 }
}

enum BrewCask {
    static let stableCask = "toki"
    static let betaCask = "toki-beta"
    static let tap = "aashutoshrathi/tap"

    static func qualified(_ cask: String) -> String { "\(tap)/\(cask)" }

    /// The cask whose Caskroom entry resolves to the running bundle, and the prefix owning
    /// it. The `app` stanza moves the bundle out of the Caskroom and leaves a symlink
    /// pointing at it, so only the cask side can see the relationship - which also keeps
    /// detection independent of `--appdir`. Intel Homebrew lives under /usr/local, so more
    /// than one base has to be probed.
    static func installedCask(
        bundleURL: URL,
        caskroomBases: [URL],
        caskNames: [String] = [stableCask, betaCask]
    ) -> BrewCaskInstall? {
        let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        for base in caskroomBases {
            guard let cask = caskNames.first(where: { name in
                appPaths(in: base.appendingPathComponent(name)).contains(resolvedBundle)
            }) else { continue }
            return BrewCaskInstall(cask: cask, brewPrefix: base.deletingLastPathComponent().path)
        }
        return nil
    }

    private static func appPaths(in caskDir: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: caskDir,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.map {
            $0.appendingPathComponent("Toki.app").resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    static func cask(for channel: UpdateChannel) -> String {
        channel == .beta ? betaCask : stableCask
    }

    static func channel(for cask: String) -> UpdateChannel {
        cask == betaCask ? .beta : .stable
    }

    /// Only the beta cask carries prereleases, so the stable cask can never deliver one.
    static func canDeliver(cask: String, isPrerelease: Bool) -> Bool {
        !isPrerelease || cask == betaCask
    }

    /// `conflicts_with` makes brew refuse to install either cask while the other is
    /// present, so a switch is uninstall-then-install. Fetching first matters because the
    /// uninstall deletes the bundle this process runs from: a download that fails after
    /// that point would leave no app on disk.
    static func switchCommands(from installed: String, to target: String) -> [[String]] {
        [
            ["fetch", "--cask", target],
            ["uninstall", "--cask", installed],
            ["install", "--cask", target],
        ]
    }

    /// Homebrew records cask trust per cask, not per tap, so installing `toki` never trusts
    /// `toki-beta` and every switch command against the target is refused until this runs.
    static func trustCommand(for cask: String) -> [String] {
        ["trust", "--cask", qualified(cask)]
    }

    static func isUninstall(_ command: [String]) -> Bool {
        command.first == "uninstall"
    }

    /// Runs off the main actor because brew takes minutes.
    static func run(_ arguments: [String], brewBinary: String) async -> BrewCaskResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brewBinary)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    // Drain before waiting, or a step that fills the pipe buffer blocks forever.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: BrewCaskResult(
                        status: process.terminationStatus,
                        output: String(data: data, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(returning: BrewCaskResult(status: nil, output: error.localizedDescription))
                }
            }
        }
    }

    static func failureReason(_ output: String) -> String? {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let reason = lines.last(where: { $0.hasPrefix("Error:") }) ?? lines.last else { return nil }
        return String(reason.prefix(200))
    }

    /// Parsed off disk rather than through `Bundle(url:)`, which hands back the running
    /// app's already-loaded bundle and the Info dictionary it cached before brew swapped
    /// the file - a stale read that fails every successful upgrade.
    static func handoffSucceeded(appURL: URL, expectedVersion: String) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return false }
        return handoffSucceeded(
            bundleVersion: info["TokiReleaseVersion"] as? String,
            marketingVersion: info["CFBundleShortVersionString"] as? String,
            expectedVersion: expectedVersion
        )
    }

    /// `TokiReleaseVersion` distinguishes beta iterations that share one marketing version
    /// (`-beta.1` and `-beta.2` both report `2.5.0`); without the stamp a beta is
    /// indistinguishable from its siblings, so only an exact stable match can pass.
    static func handoffSucceeded(bundleVersion: String?, marketingVersion: String?, expectedVersion: String) -> Bool {
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion == expectedVersion
        }
        guard let marketingVersion, !expectedVersion.contains("-") else { return false }
        return marketingVersion == expectedVersion
    }
}
