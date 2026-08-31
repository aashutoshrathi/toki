import Foundation

/// Routes in-app updates through Homebrew when a cask installed this copy of Toki.
///
/// The updater's DMG swap replaces the bundle in place, which desyncs brew's receipt from
/// the app on disk; a later `brew upgrade` then clobbers the newer build. Handing the
/// install to `brew upgrade` keeps receipt, Caskroom, and bundle in agreement.
struct BrewCaskInstall: Equatable, Sendable {
    let cask: String
    let brewPrefix: String

    var brewBinary: String { brewPrefix + "/bin/brew" }
}

enum BrewCask {
    static let stableCask = "toki"
    static let betaCask = "toki-beta"

    /// The cask (and the brew prefix owning it) whose Caskroom entry resolves to the
    /// running bundle. The `app` stanza moves the bundle out of the Caskroom and leaves a
    /// symlink pointing at it, so the cask side is the one that must be enumerated and
    /// resolved; resolving the bundle path alone can never see an inbound symlink. That
    /// also makes detection independent of `--appdir`. Both prefixes are probed because
    /// Intel Homebrew lives under /usr/local, not /opt/homebrew.
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

    /// Only the beta cask tracks prereleases. Handing a prerelease to the stable cask
    /// would upgrade to whatever stable version the tap holds, or no-op — either way the
    /// offered build never arrives, so the mismatch is reported instead of attempted.
    static func canDeliver(cask: String, isPrerelease: Bool) -> Bool {
        !isPrerelease || cask == betaCask
    }

    /// Exit status of `brew upgrade`, or nil when brew could not be launched at all —
    /// the two cases need different advice, and a missing brew is not a failed upgrade.
    ///
    /// Off the main actor: an upgrade can run for minutes and the menu bar must stay
    /// responsive. Termination is observed via waitpid exit, not a pipe read, so there is
    /// no stdout/stderr drain to deadlock on.
    static func runUpgrade(_ install: BrewCaskInstall) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: install.brewBinary)
                process.arguments = ["upgrade", "--cask", install.cask]
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Postcondition after the handoff, read from the replaced bundle's Info.plist.
    ///
    /// The plist is parsed off disk rather than through `Bundle(url:)`, which returns the
    /// already-loaded Bundle for a path Foundation has seen - always true of the running
    /// app - along with the Info dictionary it cached before brew swapped the bundle. That
    /// stale read reports the old version and fails every successful upgrade.
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

    /// The stamped `TokiReleaseVersion` distinguishes beta iterations that share one
    /// marketing version (`2.5.0-beta.1` vs `-beta.2` both report `2.5.0`); without the
    /// stamp only an exact stable match can pass, because a beta iteration is then
    /// indistinguishable from its siblings.
    static func handoffSucceeded(bundleVersion: String?, marketingVersion: String?, expectedVersion: String) -> Bool {
        if let bundleVersion, !bundleVersion.isEmpty {
            return bundleVersion == expectedVersion
        }
        guard let marketingVersion, !expectedVersion.contains("-") else { return false }
        return marketingVersion == expectedVersion
    }
}
