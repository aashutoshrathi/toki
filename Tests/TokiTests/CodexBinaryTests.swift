import Foundation
import XCTest
@testable import Toki

final class CodexBinaryTests: XCTestCase {
    // MARK: - The ladder

    // Injects a probe closure so a real `codex` on the runner's PATH can't bleed in - this is the
    // regression guard against a future refactor letting the app's version-locked CLI shadow a
    // newer PATH install.
    func testPathInstallWinsWhenBothPresent() {
        let binary = CodexBinaryResolver.resolve(
            pathProbe: { "/usr/local/bin/codex" },
            candidates: ["/Applications/Codex.app/Contents/Resources"],
            isExecutable: { _ in true }
        )
        XCTAssertEqual(binary, .pathInstall("/usr/local/bin/codex"))
    }

    func testAppBundleUsedWhenCLIAbsent() {
        let bundleDir = "/Applications/Codex.app/Contents/Resources"
        let binary = CodexBinaryResolver.resolve(
            pathProbe: { nil },
            candidates: [bundleDir],
            isExecutable: { $0 == bundleDir + "/codex" }
        )
        XCTAssertEqual(binary, .appBundle(bundleDir + "/codex"))
    }

    func testNilWhenNeitherPresent() {
        let binary = CodexBinaryResolver.resolve(
            pathProbe: { nil },
            candidates: ["/Applications/Codex.app/Contents/Resources"],
            isExecutable: { _ in false }
        )
        XCTAssertNil(binary)
    }

    // A probe result that isn't a single absolute path (an alias/function name, empty, multi-line)
    // is rejected and the ladder falls through to the bundle.
    func testNonAbsoluteProbeResultIsRejected() {
        let bundleDir = "/Applications/Codex.app/Contents/Resources"
        let binary = CodexBinaryResolver.resolve(
            pathProbe: { "codex" },
            candidates: [bundleDir],
            isExecutable: { $0.hasPrefix("/Applications") }
        )
        XCTAssertEqual(binary, .appBundle(bundleDir + "/codex"))
    }

    // MARK: - Candidate filtering

    func testRegularExecutableIsAccepted() throws {
        let directory = try makeTemporaryDirectory()
        let codex = directory.appendingPathComponent("codex")
        try writeExecutable(at: codex)
        XCTAssertTrue(CodexBinaryResolver.isRegularExecutable(codex.path))
    }

    func testNonExecutableFileIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let codex = directory.appendingPathComponent("codex")
        try Data("not runnable".utf8).write(to: codex)
        XCTAssertFalse(CodexBinaryResolver.isRegularExecutable(codex.path))
    }

    func testDirectoryIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let codex = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: false)
        XCTAssertFalse(CodexBinaryResolver.isRegularExecutable(codex.path))
    }

    func testCandidateWithoutCodexIsSkipped() throws {
        let withCodex = try makeTemporaryDirectory()
        try writeExecutable(at: withCodex.appendingPathComponent("codex"))
        let withoutCodex = try makeTemporaryDirectory()

        let binary = CodexBinaryResolver.resolve(
            pathProbe: { nil },
            candidates: [withoutCodex.path, withCodex.path],
            isExecutable: CodexBinaryResolver.isRegularExecutable
        )
        XCTAssertEqual(binary, .appBundle(withCodex.appendingPathComponent("codex").path))
    }

    // MARK: - Shell probe

    // A fully controlled PATH (temp dir only, no inherited tail) so whence -p's answer is
    // deterministic on any runner.
    func testShellProbeFindsExecutableOnControlledPath() throws {
        let directory = try makeTemporaryDirectory()
        let codex = directory.appendingPathComponent("codex")
        try writeExecutable(at: codex)

        let probed = try CodexBinaryResolver.probeCodexOnPath(directory.path)
        XCTAssertEqual(probed, codex.path)
    }

    func testShellProbeReturnsNilOnEmptyPath() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertNil(try CodexBinaryResolver.probeCodexOnPath(directory.path))
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeExecutable(at url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
