import SwiftUI

// Loads the bundled CHANGELOG.md (see Sources/Toki/Resources/CHANGELOG.md, a symlink to the
// repo-root copy so there's one source of truth) the same way SVGLogoAsset resolves other
// bundled resources - raw files in Contents/Resources, not an SPM resource bundle.
private enum ChangelogAsset {
    @MainActor private static var cached: String??

    // #filePath is this source file's absolute path on whichever machine compiled it - only
    // meaningful for local dev builds (`swift run`/`swift build`), where it correctly points
    // at the real repo-root CHANGELOG.md. That's needed because the symlink at
    // Sources/Toki/Resources/CHANGELOG.md doesn't survive SPM's own resource-bundling step
    // for that workflow: SPM copies it as a symlink rather than dereferencing it (unlike the
    // plain `cp` in the packaging scripts), so the relative target - correct from
    // Sources/Toki/Resources - resolves to a nonexistent path once relocated into the
    // differently-nested Toki_Toki.bundle. In a shipped release .app this candidate simply
    // won't exist on disk, which is fine - the earlier candidates already succeed there.
    private static let devRepoRootChangelog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Views
        .deletingLastPathComponent() // Toki
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("CHANGELOG.md")

    @MainActor static func text() -> String? {
        if let cached { return cached }
        let urls = [
            Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            Bundle.main.resourceURL?.appendingPathComponent("CHANGELOG.md"),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/CHANGELOG.md"),
            devRepoRootChangelog
        ]
        let content = urls.compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
        cached = content
        return content
    }
}

private struct ChangelogRelease: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let sections: [ChangelogSection]
}

private struct ChangelogSection: Identifiable {
    var id: String { title }
    let title: String
    let items: [String]
}

// Hand-rolled instead of a general markdown renderer - CHANGELOG.md's shape here is fixed
// (## version - date, ### section, - item) and AttributedString(markdown:) doesn't turn
// that structure into visual headings/bullets anyway, only inline emphasis. The inline
// emphasis is the half worth having, and `inlineMarkdown` below applies it to each item once
// the structure has been peeled off.
private func parseChangelog(_ raw: String) -> [ChangelogRelease] {
    var releases: [ChangelogRelease] = []
    var currentVersion: String?
    var currentDate = ""
    var currentSections: [ChangelogSection] = []
    var currentSectionTitle: String?
    var currentItems: [String] = []

    func flushSection() {
        if let title = currentSectionTitle, !currentItems.isEmpty {
            currentSections.append(ChangelogSection(title: title, items: currentItems))
        }
        currentSectionTitle = nil
        currentItems = []
    }

    func flushRelease() {
        flushSection()
        if let version = currentVersion {
            releases.append(ChangelogRelease(version: version, date: currentDate, sections: currentSections))
        }
        currentVersion = nil
        currentDate = ""
        currentSections = []
    }

    for substring in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(substring)
        if line.hasPrefix("## ") {
            flushRelease()
            let header = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let parts = header.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            currentVersion = parts.first
            currentDate = parts.count > 1 ? parts[1] : ""
        } else if line.hasPrefix("### ") {
            flushSection()
            currentSectionTitle = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("- ") {
            currentItems.append(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
    }
    flushRelease()
    return releases
}

// Every entry leads with a bold summary and most carry code spans or contributor links, so
// without this the panel shows the asterisks and bracket syntax as literal text.
// inlineOnlyPreservingWhitespace is the right mode here: the block structure is already
// parsed above, and the full parser would collapse an item into its own paragraph run.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
    )) ?? AttributedString(text)
}

// Entries use a bold lead sentence as their user-facing headline. Keep the complete item in
// the expanded notes, including links and technical detail, rather than truncating source text.
func changelogHeadline(_ item: String) -> String {
    guard item.hasPrefix("**"),
          let end = item.dropFirst(2).range(of: "**") else { return item }
    return String(item[..<end.upperBound])
}

struct ChangelogPage: View {
    var onClose: () -> Void
    @State private var showsLatestDetails = false
    @State private var expandedVersions: Set<String> = []

    private var releases: [ChangelogRelease] {
        guard let raw = ChangelogAsset.text() else { return [] }
        return parseChangelog(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .functionalControlStyle()
                .help("Back")
                .accessibilityLabel("Back")
                .pointerOnHover()
                Text("What’s new")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            if let latest = releases.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        latestCard(latest)
                        if releases.count > 1 {
                            Text("Earlier releases")
                                .font(.system(size: 13, weight: .semibold))
                            ForEach(Array(releases.dropFirst())) { release in
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expandedVersions.contains(release.version) },
                                    set: { expanded in
                                        if expanded { expandedVersions.insert(release.version) }
                                        else { expandedVersions.remove(release.version) }
                                    }
                                )) {
                                    releaseNotes(release)
                                        .padding(.top, 8)
                                } label: {
                                    releaseHeading(release)
                                }
                                .padding(10)
                                .contentSurface()
                            }
                        }
                    }
                }
            } else {
                Text("Release notes are unavailable in this build.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func latestCard(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest release")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            releaseHeading(release)
            if !showsLatestDetails {
                ForEach(Array(release.sections.flatMap(\.items).prefix(4)), id: \.self) { item in
                    bullet(changelogHeadline(item))
                }
            }
            DisclosureGroup("Complete release notes", isExpanded: $showsLatestDetails) {
                releaseNotes(release)
                    .padding(.top, 8)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentSurface()
    }

    private func releaseHeading(_ release: ChangelogRelease) -> some View {
        HStack(spacing: 8) {
            Text(release.version == "Unreleased" ? release.version : "v\(release.version)")
                .font(.system(size: 13, weight: .semibold))
            if !release.date.isEmpty {
                Text(release.date)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func releaseNotes(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(section.items, id: \.self) { item in
                        bullet(item)
                    }
                }
            }
        }
    }

    private func bullet(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(inlineMarkdown(item))
                .fixedSize(horizontal: false, vertical: true)
                .tint(.accentColor)
        }
        .font(.system(size: 11))
    }
}
