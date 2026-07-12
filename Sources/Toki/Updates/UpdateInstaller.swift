import AppKit
import Foundation

struct PreparedUpdate {
    let stagedAppURL: URL
    let targetAppURL: URL
}

// Reference box so the concurrent stderr read can hand its result back across the
// DispatchGroup barrier without capturing a mutable local (which the compiler flags).
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum UpdateInstaller {
    static func prepare(downloadURL: URL, expectedVersion: String) async throws -> PreparedUpdate {
        guard downloadURL.scheme == "https", downloadURL.host == "github.com", downloadURL.pathExtension.lowercased() == "dmg" else {
            throw LocalizedErrorMessage("The release download is not a trusted GitHub DMG.")
        }

        var request = URLRequest(url: downloadURL)
        request.setValue(appUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (temporaryDownload, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalizedErrorMessage("GitHub could not download the update.")
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let dmgURL = workingDirectory.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: temporaryDownload, to: dmgURL)

        var mountURL: URL?
        do {
            mountURL = try mount(dmgURL)
            guard let mountedURL = mountURL,
                  let sourceApp = try FileManager.default.contentsOfDirectory(
                    at: mountedURL,
                    includingPropertiesForKeys: nil
                  ).first(where: { $0.lastPathComponent == "Toki.app" }) else {
                throw LocalizedErrorMessage("The update DMG does not contain Toki.app.")
            }

            try verify(app: sourceApp, expectedVersion: expectedVersion)
            let stagedApp = workingDirectory.appendingPathComponent("Toki.app", isDirectory: true)
            try FileManager.default.copyItem(at: sourceApp, to: stagedApp)

            try unmount(mountedURL)
            mountURL = nil
            try? FileManager.default.removeItem(at: dmgURL)

            return PreparedUpdate(stagedAppURL: stagedApp, targetAppURL: installedAppURL())
        } catch {
            if let mountURL { try? unmount(mountURL) }
            try? FileManager.default.removeItem(at: workingDirectory)
            throw error
        }
    }

    static func launchHelper(for update: PreparedUpdate) throws {
        guard let executable = Bundle.main.executableURL else {
            throw LocalizedErrorMessage("Toki could not locate its update helper.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--install-update",
            update.stagedAppURL.path,
            update.targetAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        try process.run()
    }

    static func runHelperIfRequested(arguments: [String]) -> Bool {
        guard arguments.count == 5, arguments[1] == "--install-update" else { return false }
        let stagedApp = URL(fileURLWithPath: arguments[2])
        let targetApp = URL(fileURLWithPath: arguments[3])
        // Fail safe: a malformed PID means continue normal startup, not exit the app.
        guard let parentPID = Int32(arguments[4]) else { return false }

        while kill(parentPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.2)
        }

        let fileManager = FileManager.default
        let backup = targetApp.deletingLastPathComponent()
            .appendingPathComponent("Toki.previous.app", isDirectory: true)
        do {
            try fileManager.createDirectory(at: targetApp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: backup)
            if fileManager.fileExists(atPath: targetApp.path) {
                try fileManager.moveItem(at: targetApp, to: backup)
            }
            do {
                try fileManager.moveItem(at: stagedApp, to: targetApp)
            } catch {
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: targetApp)
                }
                throw error
            }
            try? fileManager.removeItem(at: backup)
            try? fileManager.removeItem(at: stagedApp.deletingLastPathComponent())

            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [targetApp.path]
            try open.run()
        } catch {
            DiagnosticLogger.shared.record(.error, component: "updater_helper", code: "replace_failed", detail: diagnosticErrorDetail(error))
            DiagnosticLogger.shared.flush()
            fputs("Toki update failed: \(error.localizedDescription)\n", stderr)
        }
        return true
    }

    private static func installedAppURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Toki.app", isDirectory: true)
    }

    private static func verify(app: URL, expectedVersion: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "local.toki",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else {
            throw LocalizedErrorMessage("The downloaded app identity or version does not match the release.")
        }
        _ = try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
    }

    private static func mount(_ dmgURL: URL) throws -> URL {
        let data = try run("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw LocalizedErrorMessage("Toki could not mount the update DMG.")
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    private static func unmount(_ mountURL: URL) throws {
        _ = try run("/usr/bin/hdiutil", arguments: ["detach", mountURL.path])
    }

    private static func run(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Keep stdout and stderr separate (stdout is parsed as a plist for hdiutil), but
        // drain them concurrently so neither pipe can fill and deadlock the child.
        let errBox = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        let errData = errBox.data
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            let errDetail = String(data: errData, encoding: .utf8) ?? ""
            let message = [detail, errDetail]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw LocalizedErrorMessage(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
