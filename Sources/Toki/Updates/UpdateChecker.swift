import AppKit
import Foundation

struct AvailableUpdate: Equatable {
    let version: String
    let releaseURL: URL
    let downloadURL: URL
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
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isInstalling = false
    @Published private(set) var installError: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var checkMessage: String?

    private let session: URLSession
    private let currentVersion: String
    private let latestReleaseURL: URL
    private let defaults: UserDefaults
    private let mockVersion: String?
    private var checkTimer: Timer?

    init(
        session: URLSession = .shared,
        currentVersion: String = appVersion,
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/aashutoshrathi/toki/releases/latest")!,
        defaults: UserDefaults = .standard,
        mockVersion: String? = ProcessInfo.processInfo.environment["TOKI_MOCK_UPDATE_VERSION"]
    ) {
        self.session = session
        self.currentVersion = currentVersion
        self.latestReleaseURL = latestReleaseURL
        self.defaults = defaults
        self.mockVersion = mockVersion
        lastCheckedAt = defaults.object(forKey: lastUpdateCheckKey) as? Date
    }

    func startAutomaticChecks() {
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

    func dismiss() {
        guard let availableUpdate else { return }
        defaults.set(availableUpdate.version, forKey: dismissedVersionKey)
        self.availableUpdate = nil
    }

    func openRelease() {
        guard let url = availableUpdate?.releaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    func installUpdate() {
        guard let availableUpdate, !isInstalling else { return }
        isInstalling = true
        installError = nil

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

    private func runCheck(isManual: Bool = false) {
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

    private func scheduleNextCheck() {
        checkTimer?.invalidate()
        let elapsed = Date().timeIntervalSince(lastCheckedAt ?? .distantPast)
        let delay = max(updateCheckInterval - elapsed, 1)
        checkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runCheck() }
        }
    }

    private func checkForUpdates() async {
        if let mockVersion {
            let version = normalizedVersion(mockVersion)
            guard isNewerVersion(version, than: currentVersion),
                  let url = URL(string: "https://github.com/aashutoshrathi/toki/releases/tag/v\(version)"),
                  let downloadURL = URL(string: "https://github.com/aashutoshrathi/toki/releases/download/v\(version)/Toki_\(version)_universal.dmg") else {
                return
            }
            availableUpdate = AvailableUpdate(version: version, releaseURL: url, downloadURL: downloadURL)
            checkMessage = nil
            return
        }

        do {
            var request = URLRequest(url: latestReleaseURL)
            request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                checkMessage = "Couldn't check for updates."
                return
            }
            if http.statusCode == 429 {
                checkMessage = nil
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                checkMessage = "Couldn't check for updates."
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let releaseVersion = normalizedVersion(release.tagName)
            guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                checkMessage = "The latest release has no DMG."
                return
            }
            guard release.htmlURL.scheme == "https", release.htmlURL.host == "github.com",
                  asset.browserDownloadURL.scheme == "https", asset.browserDownloadURL.host == "github.com" else {
                checkMessage = "The release metadata is not trusted."
                return
            }

            guard isNewerVersion(releaseVersion, than: currentVersion) else {
                availableUpdate = nil
                checkMessage = "Toki is up to date."
                return
            }

            guard defaults.string(forKey: dismissedVersionKey) != releaseVersion else {
                checkMessage = "Toki \(releaseVersion) was dismissed."
                return
            }

            availableUpdate = AvailableUpdate(
                version: releaseVersion,
                releaseURL: release.htmlURL,
                downloadURL: asset.browserDownloadURL
            )
            checkMessage = nil
        } catch {
            DiagnosticLogger.shared.record(.warning, component: "updater", code: "check_failed", detail: diagnosticErrorDetail(error))
            checkMessage = "Couldn’t check for updates."
            // Update checks must never interrupt normal app startup.
        }
    }
}

private let dismissedVersionKey = "dismissedUpdateVersion"
private let lastUpdateCheckKey = "lastUpdateCheckAt"
private let updateCheckInterval: TimeInterval = 5 * 60

private func normalizedVersion(_ value: String) -> String {
    var version = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.lowercased().hasPrefix("v") {
        version.removeFirst()
    }
    return version
}

private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    candidate.compare(
        normalizedVersion(current),
        options: [.numeric, .caseInsensitive]
    ) == .orderedDescending
}
