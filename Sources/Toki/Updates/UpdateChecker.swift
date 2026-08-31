import AppKit
import Foundation

/// Which GitHub releases the updater is willing to offer.
///
/// Beta maps onto GitHub prereleases (tags like `v2.5.0-beta.1`). Stable keeps using the
/// `releases/latest` endpoint, which GitHub already restricts to full releases, so stable
/// users never see a prerelease no matter what is published.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: return "Stable"
        case .beta: return "Beta"
        }
    }
}

struct AvailableUpdate: Equatable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL
    let isPrerelease: Bool
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isInstalling = false
    @Published private(set) var installError: String?
    @Published private(set) var isSwitchingCask = false
    @Published private(set) var caskSwitchError: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var checkMessage: String?
    @Published private(set) var channel: UpdateChannel

    private let session: URLSession
    private let currentVersion: String
    private let latestReleaseURL: URL
    private let releaseListURL: URL
    private let defaults: UserDefaults
    private let mockVersion: String?
    private var checkTimer: Timer?

    // The full release identity of this build, including any prerelease suffix, so a beta can see
    // the next beta and the eventual stable. Release DMGs carry it in Info.plist; local/dev builds
    // fall back to the marketing version.
    nonisolated static var installedVersion: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TokiReleaseVersion") as? String,
              !value.isEmpty else {
            return appVersion
        }
        return value
    }

    init(
        session: URLSession = .shared,
        currentVersion: String = UpdateChecker.installedVersion,
        apiBaseURL: URL = URL(string: "https://api.github.com/repos/aashutoshrathi/toki")!,
        defaults: UserDefaults = .standard,
        mockVersion: String? = ProcessInfo.processInfo.environment["TOKI_MOCK_UPDATE_VERSION"]
    ) {
        self.session = session
        self.currentVersion = currentVersion
        self.latestReleaseURL = apiBaseURL.appendingPathComponent("releases/latest")
        // Enough pages of history that a stable release stays visible behind a run of betas;
        // the newest published release is first, so 20 is generous.
        self.releaseListURL = URL(string: apiBaseURL.appendingPathComponent("releases").absoluteString + "?per_page=20")!
        self.defaults = defaults
        self.mockVersion = mockVersion
        self.channel = UpdateChannel(rawValue: defaults.string(forKey: updateChannelKey) ?? "") ?? .stable
        lastCheckedAt = defaults.object(forKey: lastUpdateCheckKey) as? Date
    }

    func startAutomaticChecks() {
        adoptChannelOfInstalledCask()
        if mockVersion != nil {
            runCheck()
            return
        }
        let elapsed = Date().timeIntervalSince(lastCheckedAt ?? .distantPast)
        if elapsed >= updateCheckInterval {
            runCheck()
        } else {
            scheduleNextCheck()
        }
    }

    func checkNow() {
        runCheck(isManual: true)
    }

    /// Switching channels re-checks immediately: the point of opting into beta is to get the
    /// prerelease now, not at the next five-minute tick. The stale offer is cleared first so a
    /// beta banner can't linger after switching back to stable.
    func setChannel(_ newChannel: UpdateChannel) {
        guard newChannel != channel, !isSwitchingCask else { return }
        storeChannel(newChannel)
        availableUpdate = nil
        caskSwitchError = nil

        // A brew install follows its cask, not this preference, so the picker has to move
        // the install too or the two silently disagree.
        let target = BrewCask.cask(for: newChannel)
        guard let install = brewInstall(), install.cask != target else {
            checkNow()
            return
        }
        isSwitchingCask = true
        Task { await performCaskSwitch(install: install, target: target) }
    }

    /// The reverse of `setChannel`: a cask swapped with brew directly moves the preference
    /// with it. The cask is the authority, since it decides what brew will install.
    private func adoptChannelOfInstalledCask() {
        guard !isSwitchingCask, let install = brewInstall() else { return }
        let owned = BrewCask.channel(for: install.cask)
        guard owned != channel else { return }
        storeChannel(owned)
        availableUpdate = nil
    }

    private func storeChannel(_ newChannel: UpdateChannel) {
        channel = newChannel
        defaults.set(newChannel.rawValue, forKey: updateChannelKey)
    }

    private func brewInstall() -> BrewCaskInstall? {
        BrewCask.installedCask(
            bundleURL: Bundle.main.bundleURL,
            caskroomBases: [
                URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
                URL(fileURLWithPath: "/usr/local/Caskroom"),
            ]
        )
    }

    private func performCaskSwitch(install: BrewCaskInstall, target: String) async {
        for command in BrewCask.switchCommands(from: install.cask, to: target) {
            guard await BrewCask.run(command, brewBinary: install.brewBinary) == 0 else {
                await recoverFromFailedCaskSwitch(install: install, target: target)
                return
            }
        }
        isSwitchingCask = false
        // The bundle on disk is a different build now, so the running process is stale.
        if !relaunchAfterBrewChange() {
            caskSwitchError = "Switched to the \(target) cask. Reopen Toki to finish."
            return
        }
        NSApp.terminate(nil)
    }

    /// The uninstall runs before the install, so a failure can leave no app on disk at all.
    /// Reinstalling what was there is the only way back, and the preference follows it so
    /// the picker keeps describing what is installed.
    private func recoverFromFailedCaskSwitch(install: BrewCaskInstall, target: String) async {
        let restored = await BrewCask.run(["install", "--cask", install.cask], brewBinary: install.brewBinary) == 0
        DiagnosticLogger.shared.record(
            .error, component: "updater", code: "cask_switch_failed", detail: "to=\(target) restored=\(restored)"
        )
        storeChannel(BrewCask.channel(for: install.cask))
        isSwitchingCask = false
        caskSwitchError = restored
            ? "Couldn't switch to the \(target) cask, so nothing changed."
            : "Switching to the \(target) cask failed and Toki may be gone from Applications. Run `brew install --cask \(target)`."
    }


    func dismiss() {
        guard let availableUpdate else { return }
        defaults.set(availableUpdate.version, forKey: dismissedVersionKey)
        self.availableUpdate = nil
    }

    /// Hides this version's banner for a while rather than for good.
    ///
    /// Dismissing was all-or-nothing: the only way to clear the banner was to skip the version
    /// entirely, so anyone who wanted to update later - just not now - had to either leave it on
    /// screen or silently opt out of the release. Snoozing is recorded against the version, so a
    /// newer release still surfaces immediately instead of inheriting the quiet period.
    func snooze(hours: Int = 6) {
        guard let availableUpdate else { return }
        defaults.set(availableUpdate.version, forKey: snoozedVersionKey)
        defaults.set(Date().addingTimeInterval(TimeInterval(hours) * 3600), forKey: snoozedUntilKey)
        self.availableUpdate = nil
    }

    /// Extracted so the window logic is testable without waiting six hours.
    ///
    /// nonisolated: pure comparison over values. Without it the method inherits the class's
    /// MainActor isolation and cannot be called from a synchronous test.
    nonisolated static func isSnoozed(
        version: String,
        snoozedVersion: String?,
        snoozedUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        guard snoozedVersion == version, let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    func openRelease() {
        guard let url = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    func installUpdate() {
        guard let availableUpdate, !isInstalling else { return }
        isInstalling = true
        installError = nil
        guard !startBrewHandoff(for: availableUpdate) else { return }

        Task {
            do {
                let prepared = try await UpdateInstaller.prepare(
                    downloadURL: availableUpdate.downloadURL,
                    expectedVersion: availableUpdate.version
                )
                try UpdateInstaller.launchHelper(for: prepared)
                NSApp.terminate(nil)
            } catch {
                DiagnosticLogger.shared.record(.error, component: "updater", code: "install_failed", detail: diagnosticErrorDetail(error))
                installError = error.localizedDescription
                isInstalling = false
            }
        }
    }

    /// A cask-installed copy must be upgraded by brew, not swapped underneath it: the DMG
    /// path would desync brew's receipt and the next `brew upgrade` would clobber this
    /// newer build with the cask's older one. Returns true once the install belongs to brew
    /// - handed over or refused - so the DMG path does not also run.
    private func startBrewHandoff(for update: AvailableUpdate) -> Bool {
        guard let install = brewInstall() else { return false }

        guard BrewCask.canDeliver(cask: install.cask, isPrerelease: update.isPrerelease) else {
            failBrewHandoff(
                code: "brew_channel_mismatch",
                message: "Beta builds ship in the \(BrewCask.betaCask) cask. Pick Beta in Settings > Updates to move this install onto it."
            )
            return true
        }
        Task { await installViaBrew(install: install, update: update) }
        return true
    }

    private func installViaBrew(install: BrewCaskInstall, update: AvailableUpdate) async {
        let cask = install.cask
        let manually = "Update with `brew upgrade --cask \(cask)`."
        guard let status = await BrewCask.run(["upgrade", "--cask", cask], brewBinary: install.brewBinary) else {
            failBrewHandoff(code: "brew_missing", message: "Couldn't run \(install.brewBinary). \(manually)")
            return
        }

        guard status == 0, BrewCask.handoffSucceeded(
            appURL: UpdateInstaller.installedAppURL(),
            expectedVersion: update.version
        ) else {
            failBrewHandoff(code: "brew_handoff_failed", message: "brew finished but Toki wasn't updated. \(manually)", detail: "exit=\(status)")
            return
        }

        guard relaunchAfterBrewChange() else {
            // The upgrade landed but relaunching failed; keep the app up rather than
            // close it, and tell the user how to get the new build running.
            installError = "Toki was updated but couldn't relaunch. Reopen Toki to finish."
            isInstalling = false
            return
        }
        NSApp.terminate(nil)
    }

    private func failBrewHandoff(code: String, message: String, detail: String? = nil) {
        DiagnosticLogger.shared.record(.error, component: "updater", code: code, detail: detail ?? message)
        installError = message
        isInstalling = false
    }

    /// Reopens the app after brew replaced the bundle; these casks have no quit/reopen
    /// stanza, so an upgrade or switch would otherwise just close Toki. The waiter is
    /// `/bin/sh`, not Toki's own binary, because a channel switch can install an older
    /// build that need not understand a private flag. It has to outlive this process:
    /// `open` fired any earlier is routed back to the running instance.
    private func relaunchAfterBrewChange() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            UpdateInstaller.installedAppURL().path,
        ]
        do {
            try process.run()
            return true
        } catch {
            DiagnosticLogger.shared.record(.error, component: "updater", code: "brew_relaunch_failed", detail: diagnosticErrorDetail(error))
            return false
        }
    }

    private func runCheck(isManual: Bool = false) {
        adoptChannelOfInstalledCask()
        guard !isChecking else { return }
        isChecking = true
        if isManual { checkMessage = nil }

        Task {
            await checkForUpdates()
            let checkedAt = Date()
            lastCheckedAt = checkedAt
            defaults.set(checkedAt, forKey: lastUpdateCheckKey)
            isChecking = false
            scheduleNextCheck()
        }
    }

    // A repeating timer in the common run loop modes, deliberately.
    //
    // The previous version chained one-shot timers, each scheduling the next from inside its
    // own fire handler. That makes the chain a single point of failure: if any one firing is
    // missed or the timer is invalidated without a successor being scheduled, checking stops
    // permanently and the app sits on a stale update forever - which is exactly the reported
    // symptom of "an update is available and it never notices the newer ones behind it".
    //
    // It was also scheduled in the default run loop mode only, so it could not fire while the
    // popover or a menu was tracking. A repeating timer added to .common survives both: a
    // missed firing is skipped, not fatal, because the next one is already scheduled.
    private func scheduleNextCheck() {
        guard checkTimer == nil else { return }
        let timer = Timer(timeInterval: updateCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runCheck() }
        }
        // Honour time already elapsed since the last check so a relaunch doesn't restart the
        // full interval; subsequent firings then settle onto the regular cadence.
        let elapsed = Date().timeIntervalSince(lastCheckedAt ?? .distantPast)
        timer.fireDate = Date().addingTimeInterval(max(updateCheckInterval - elapsed, 1))
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func checkForUpdates() async {
        if let mockVersion {
            let version = Self.normalizedVersion(mockVersion)
            guard Self.isNewerVersion(version, than: currentVersion),
                  let url = URL(string: "https://github.com/aashutoshrathi/toki/releases/tag/v\(version)"),
                  let downloadURL = URL(string: "https://github.com/aashutoshrathi/toki/releases/download/v\(version)/Toki_\(version)_universal.dmg") else {
                return
            }
            availableUpdate = AvailableUpdate(
                version: version,
                releaseURL: url,
                downloadURL: downloadURL,
                isPrerelease: version.contains("-")
            )
            checkMessage = nil
            return
        }

        do {
            guard let release = try await fetchCandidateRelease() else { return }
            let releaseVersion = Self.normalizedVersion(release.tagName)
            guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                checkMessage = "The latest release has no DMG."
                return
            }
            guard release.htmlURL.scheme == "https", release.htmlURL.host == "github.com",
                  asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com" else {
                checkMessage = "The release metadata is not trusted."
                return
            }

            guard Self.isNewerVersion(releaseVersion, than: currentVersion) else {
                availableUpdate = nil
                checkMessage = "Toki is up to date."
                return
            }

            guard defaults.string(forKey: dismissedVersionKey) != releaseVersion else {
                checkMessage = "Toki \(releaseVersion) was dismissed."
                return
            }

            // Still inside a snooze window for this exact version. Checks keep running - only
            // the banner is withheld - so the moment a newer release lands it surfaces normally.
            if Self.isSnoozed(
                version: releaseVersion,
                snoozedVersion: defaults.string(forKey: snoozedVersionKey),
                snoozedUntil: defaults.object(forKey: snoozedUntilKey) as? Date
            ) {
                availableUpdate = nil
                checkMessage = "Toki \(releaseVersion) is snoozed."
                return
            }

            availableUpdate = AvailableUpdate(
                version: releaseVersion,
                releaseURL: release.htmlURL,
                downloadURL: asset.browserDownloadURL,
                isPrerelease: release.prerelease
            )
            checkMessage = nil
        } catch {
            DiagnosticLogger.shared.record(.warning, component: "updater", code: "check_failed", detail: diagnosticErrorDetail(error))
            checkMessage = "Couldn’t check for updates."
            // Update checks must never interrupt normal app startup.
        }
    }

    /// Stable asks GitHub for `releases/latest`, which excludes prereleases and drafts by
    /// definition. Beta has no equivalent endpoint, so it lists recent releases and picks the
    /// highest version among them - prereleases included. Picking by version rather than list
    /// order matters for graduation: once `2.5.0` ships, someone on `2.5.0-beta.2` must be
    /// offered the stable build even if a stray older beta was published after it.
    private func fetchCandidateRelease() async throws -> GitHubRelease? {
        if channel == .stable {
            guard let data = try await fetch(latestReleaseURL) else { return nil }
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        }
        guard let data = try await fetch(releaseListURL) else { return nil }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases
            .filter { !$0.draft }
            .max { Self.compareVersions(Self.normalizedVersion($0.tagName), Self.normalizedVersion($1.tagName)) == .orderedAscending }
    }

    /// Returns nil when the response was handled as a status message (rate limit, HTTP error).
    private func fetch(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            checkMessage = "Couldn't check for updates."
            return nil
        }
        if http.statusCode == 429 {
            checkMessage = nil
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            checkMessage = "Couldn't check for updates."
            return nil
        }
        return data
    }

    nonisolated static func normalizedVersion(_ value: String) -> String {
        var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        return version
    }

    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        compareVersions(candidate, normalizedVersion(current)) == .orderedDescending
    }

    /// Semver-aware ordering, which the previous `String.compare(options: .numeric)` was not:
    /// that ordering ranks `2.5.0-beta.1` above `2.5.0` because the prerelease tag makes the
    /// string longer. Getting this right is what lets a beta build graduate - `2.5.0` must beat
    /// `2.5.0-beta.2` so the stable release is offered to beta testers, and must NOT beat itself
    /// so stable users aren't reinstalled in a loop.
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parseVersion(lhs)
        let right = parseVersion(rhs)

        for index in 0..<max(left.core.count, right.core.count) {
            let a = index < left.core.count ? left.core[index] : 0
            let b = index < right.core.count ? right.core[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }

        // Same core version: a full release outranks any of its prereleases.
        switch (left.prerelease.isEmpty, right.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }

        for index in 0..<max(left.prerelease.count, right.prerelease.count) {
            // Fewer identifiers sorts first (semver: `-beta` < `-beta.1`).
            guard index < left.prerelease.count else { return .orderedAscending }
            guard index < right.prerelease.count else { return .orderedDescending }
            let a = left.prerelease[index]
            let b = right.prerelease[index]
            switch (Int(a), Int(b)) {
            case let (numA?, numB?):
                if numA != numB { return numA < numB ? .orderedAscending : .orderedDescending }
            case (.some, nil):
                // Numeric identifiers sort below alphanumeric ones (semver spec rule 11).
                return .orderedAscending
            case (nil, .some):
                return .orderedDescending
            case (nil, nil):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
        }
        return .orderedSame
    }

    private nonisolated static func parseVersion(_ value: String) -> (core: [Int], prerelease: [String]) {
        // Build metadata (`+sha`) never affects precedence, so it is stripped outright.
        let withoutBuild = value.split(separator: "+", maxSplits: 1).first ?? ""
        let parts = withoutBuild.split(separator: "-", maxSplits: 1)
        let core = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        let prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return (core, prerelease)
    }
}

private let dismissedVersionKey = "dismissedUpdateVersion"
private let snoozedVersionKey = "snoozedUpdateVersion"
private let snoozedUntilKey = "snoozedUpdateUntil"
private let lastUpdateCheckKey = "lastUpdateCheckAt"
private let updateChannelKey = "updateChannel"
private let updateCheckInterval: TimeInterval = 5 * 60
