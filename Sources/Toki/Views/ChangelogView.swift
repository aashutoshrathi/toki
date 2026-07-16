import SwiftUI

// Loads the bundled CHANGELOG.md (see Sources/Toki/Resources/CHANGELOG.md, a symlink to the
// repo-root copy so there's one source of truth) the same way SVGLogoAsset resolves other
// bundled resources - raw files in Contents/Resources, not an SPM resource bundle.
private enum ChangelogAsset {
    @MainActor private static var cached: String??

    @MainActor static func text() -> String? {
        if let cached { return cached }
        let executableDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let urls = [
            Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            Bundle.main.resourceURL?.appendingPathComponent("CHANGELOG.md"),
            executableDir?.deletingLastPathComponent().appendingPathComponent("Resources/CHANGELOG.md"),
            // `swift run Toki` (the documented dev workflow, see README) never produces a
            // real .app - resources land in an SPM-generated bundle right next to the
            // executable instead of Contents/Resources, which none of the candidates above
            // reach.
            executableDir?.appendingPathComponent("Toki_Toki.bundle/CHANGELOG.md")
        ]
        let content = urls.compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
        cached = content
        return content
    }
}

private struct ChangelogRelease: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let sections: [ChangelogSection]
}

private struct ChangelogSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [String]
}

// Hand-rolled instead of a general markdown renderer - CHANGELOG.md's shape here is fixed
// (## version - date, ### section, - item) and AttributedString(markdown:) doesn't turn
// that structure into visual headings/bullets anyway, only inline emphasis.
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

struct ChangelogPage: View {
    var onClose: () -> Void

    private var releases: [ChangelogRelease] {
        guard let raw = ChangelogAsset.text() else { return [] }
        return parseChangelog(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 25, height: 25)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
                .pointerOnHover()
                Text("What's new")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            if releases.isEmpty {
                Text("Changelog unavailable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(releases) { release in
                            releaseCard(release)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func releaseCard(_ release: ChangelogRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("v\(release.version)")
                    .font(.system(size: 12, weight: .bold))
                if !release.date.isEmpty {
                    Text(release.date)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    ForEach(section.items, id: \.self) { item in
                        HStack(alignment: .top, spacing: 5) {
                            Text("-")
                                .foregroundStyle(.secondary)
                            Text(item)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 10.5))
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
