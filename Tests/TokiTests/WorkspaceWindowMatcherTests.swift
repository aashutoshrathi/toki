import XCTest
@testable import Toki

final class WorkspaceWindowMatcherTests: XCTestCase {
    private typealias Window = WorkspaceWindowMatcher.WindowInfo

    func testExactWorkspaceRootWithDocument() {
        let windows = [Window(title: "project", documentPath: "/work/project/main.swift")]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project", windows: windows), 0)
    }

    func testSubdirectoryMatchesAncestorWorkspace() {
        let windows = [Window(title: "main.swift - project", documentPath: "/work/project/src/main.swift")]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows), 0)
    }

    func testUnrelatedDeeperNameIsNotPreferredOverRealAncestor() {
        let windows = [
            Window(title: "src", documentPath: "/other/src/x.swift"),
            Window(title: "project", documentPath: "/work/project/y.swift"),
        ]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows), 1)
    }

    func testDocumentedUnrelatedWindowIsSkippedForNoDocumentFallback() {
        let windows = [
            Window(title: "src", documentPath: "/other/src/x.swift"),
            Window(title: "project", documentPath: nil),
        ]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows), 1)
    }

    func testSameTitleDisambiguatedByDocumentPathOnComponentBoundary() {
        let windows = [
            Window(title: "project", documentPath: "/work/project-old/a.swift"),
            Window(title: "project", documentPath: "/work/project/b.swift"),
        ]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows), 1)
    }

    func testSymlinkedWorkspaceRootResolvesToCanonicalDocument() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString)")
        let realProject = base.appendingPathComponent("real/project")
        try fm.createDirectory(at: realProject, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("real"))
        defer { try? fm.removeItem(at: base) }

        let cwd = base.appendingPathComponent("link/project").path
        let document = realProject.appendingPathComponent("main.swift").path
        let windows = [Window(title: "project", documentPath: document)]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: cwd, windows: windows), 0)
    }

    func testNoMatchReturnsNil() {
        let windows = [Window(title: "unrelated", documentPath: "/x/y.swift")]
        XCTAssertNil(WorkspaceWindowMatcher.pick(directory: "/work/project", windows: windows))
    }

    func testIsPathRespectsComponentBoundaries() {
        XCTAssertTrue(WorkspaceWindowMatcher.isPath("/work/project", under: "/work/project"))
        XCTAssertTrue(WorkspaceWindowMatcher.isPath("/work/project/sub/f.swift", under: "/work/project"))
        XCTAssertFalse(WorkspaceWindowMatcher.isPath("/work/project-old/a.swift", under: "/work/project"))
    }

    func testWindowWithExternalDocumentStillRaisedWhenTitleUnambiguous() {
        let windows = [Window(title: "project", documentPath: "/somewhere/else/notes.txt")]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows), 0)
    }

    func testAmbiguousSameNameWithoutConfirmingDocumentIsNotGuessed() {
        let windows = [
            Window(title: "project", documentPath: nil),
            Window(title: "project", documentPath: nil),
        ]
        XCTAssertNil(WorkspaceWindowMatcher.pick(directory: "/work/project/src", windows: windows))
    }

    func testDocumentPathAcceptsFileURLsAndPosixPathsOnly() {
        XCTAssertEqual(WorkspaceWindowMatcher.documentPath(fromRawValue: "file:///work/project/a.swift"), "/work/project/a.swift")
        XCTAssertEqual(WorkspaceWindowMatcher.documentPath(fromRawValue: "/work/project/a.swift"), "/work/project/a.swift")
        XCTAssertNil(WorkspaceWindowMatcher.documentPath(fromRawValue: "untitled:Untitled-1"))
        XCTAssertNil(WorkspaceWindowMatcher.documentPath(fromRawValue: "vscode-userdata:/foo"))
    }

    func testUntitledEditorWindowStillFallsBackToTitleMatch() {
        let windows = [Window(title: "project", documentPath: WorkspaceWindowMatcher.documentPath(fromRawValue: "untitled:Untitled-1"))]
        XCTAssertEqual(WorkspaceWindowMatcher.pick(directory: "/work/project", windows: windows), 0)
    }

    func testTitleMatchesOnlyOnFullTrailingComponent() {
        XCTAssertTrue(WorkspaceWindowMatcher.titleMatches("project", name: "project"))
        XCTAssertTrue(WorkspaceWindowMatcher.titleMatches("file - project", name: "project"))
        XCTAssertFalse(WorkspaceWindowMatcher.titleMatches("notproject", name: "project"))
    }
}
