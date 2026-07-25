import Foundation
import TokiWidgetShared
import WidgetKit

enum WidgetDataStore {
    static var appGroupURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: tokiAppGroupIdentifier)?
            .appendingPathComponent(tokiWidgetDataFilename)
    }

    static var destinationURLs: [URL] {
        // An ad-hoc signature has no stable Team ID, so macOS cannot validate its App Group
        // membership. Local builds instead use Toki's normal Application Support directory;
        // the sandboxed extension receives narrowly scoped read-only access to this one folder.
        if tokiUsesLocalWidgetData() {
            return [tokiLocalWidgetDataURL()].compactMap { $0 }
        }
        return [appGroupURL].compactMap { $0 }
    }

    static func makeSnapshot(
        entries: [MenuBarStatusEntry],
        awaitingInput: Int,
        snapshots: [AccountSnapshot],
        updatedAt: Date
    ) -> WidgetDataSnapshot {
        let widgetEntries = snapshots
            .filter { !$0.isLoadingPlaceholder }
            .map { snapshot in
                WidgetEntry(
                    id: snapshot.id,
                    provider: snapshot.provider.rawValue,
                    // Widgets are visible on the desktop even when the popover is closed. Use
                    // the provider label rather than an account name that may contain an email.
                    displayName: snapshot.provider.displayName,
                    value: widgetValue(for: snapshot),
                    remainingRatio: snapshot.remainingRatio,
                    leadingText: snapshot.emoji,
                    colorHex: snapshot.colorHex
                )
            }

        // A provider can produce a menu-bar value before its full account snapshot is ready.
        // Keep the widget useful during that narrow startup window without persisting loading
        // placeholders over an existing snapshot.
        let resolvedEntries = widgetEntries.isEmpty
            ? entries.prefix(4).map {
                WidgetEntry(
                    id: $0.provider.rawValue,
                    provider: $0.provider.rawValue,
                    displayName: $0.provider.displayName,
                    value: $0.value,
                    remainingRatio: nil,
                    leadingText: $0.leadingText,
                    colorHex: nil
                )
            }
            : Array(widgetEntries)

        let exhausted = allTrackedQuotaExhausted(snapshots)
        let suggestion = exhausted ? currentBreakSuggestion() : nil
        return WidgetDataSnapshot(
            updatedAt: updatedAt,
            entries: resolvedEntries,
            awaitingInputCount: awaitingInput,
            allExhausted: exhausted,
            breakSuggestion: suggestion.map { "\($0.emoji) \($0.menuBarText)" }
        )
    }

    static func write(
        entries: [MenuBarStatusEntry],
        awaitingInput: Int,
        snapshots: [AccountSnapshot],
        updatedAt: Date
    ) {
        guard !snapshots.isEmpty, !snapshots.allSatisfy(\.isLoadingPlaceholder) else { return }
        let urls = destinationURLs
        guard !urls.isEmpty else {
            DiagnosticLogger.shared.record(
                .warning,
                component: "widget_data",
                code: "storage_unavailable"
            )
            return
        }
        let snapshot = makeSnapshot(
            entries: entries,
            awaitingInput: awaitingInput,
            snapshots: snapshots,
            updatedAt: updatedAt
        )

        let data: Data
        do {
            data = try JSONEncoder.toki.encode(snapshot)
        } catch {
            DiagnosticLogger.shared.record(
                .error,
                component: "widget_data",
                code: "encode_failed",
                detail: diagnosticErrorDetail(error)
            )
            return
        }

        var didWrite = false
        var lastError: Error?
        for url in urls {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try SecureStore.write(data: data, to: url)
                didWrite = true
            } catch {
                lastError = error
            }
        }

        if didWrite {
            WidgetCenter.shared.reloadTimelines(ofKind: tokiWidgetKind)
            WidgetCenter.shared.reloadTimelines(ofKind: tokiQuotaRingsWidgetKind)
        } else if let lastError {
            DiagnosticLogger.shared.record(
                .error,
                component: "widget_data",
                code: "save_failed",
                detail: diagnosticErrorDetail(lastError)
            )
        }
    }

    private static func widgetValue(for snapshot: AccountSnapshot) -> String {
        if let ratio = snapshot.remainingRatio {
            return percentText(ratio)
        }
        if let value = snapshot.menuBarValue {
            return value
        }
        return snapshot.isError ? "--" : snapshot.primary
    }
}
