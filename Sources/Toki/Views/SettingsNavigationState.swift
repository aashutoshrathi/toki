import Combine
import Foundation

enum SettingsRoute: Hashable {
    case settings
    case configEditor
    case aiEditor
    case pairing
    case tailscaleGuide
    case changelog

    var title: String {
        switch self {
        case .settings: "Settings"
        case .configEditor: "Config JSON"
        case .aiEditor: "AI instructions"
        case .pairing: "Connect device"
        case .tailscaleGuide: "Tailscale setup"
        case .changelog: "What's New"
        }
    }
}

/// The source revision is the entire file: saving either editor must not erase changes
/// made by provider discovery, another editor, or an external application.
struct SettingsTextDraft: Equatable {
    var text = ""
    private(set) var baselineText: String?
    private(set) var source: String?
    var hasChanges: Bool { baselineText.map { text != $0 } ?? !text.isEmpty }

    mutating func load(text: String, source: String) {
        guard !hasChanges else { return }
        self.text = text
        baselineText = text
        self.source = source
    }

    mutating func didSave(text: String, source: String) {
        self.text = text
        baselineText = text
        self.source = source
    }

    func checkSource(_ current: String) throws {
        guard let source else {
            throw LocalizedErrorMessage("The configuration could not be read. Copy any edits you need, then discard the draft and retry reading the configuration before saving.")
        }
        guard source == current else {
            throw LocalizedErrorMessage("config.json changed since this draft was opened. Your draft is kept. Copy any edits you need, then discard the draft to reload the current configuration.")
        }
    }
}

/// Owned by the app's presentation state, so removing a page or closing the popover
/// cannot destroy a draft or its source revision.
@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published private(set) var route: SettingsRoute = .settings
    @Published var configDraft = SettingsTextDraft()
    @Published var aiDraft = SettingsTextDraft()
    @Published var configError: String?
    @Published var aiError: String?
    @Published var configSaved = false
    @Published var aiSaved = false
    @Published var scrollAnchor: String?

    var hasUnsavedDrafts: Bool { configDraft.hasChanges || aiDraft.hasChanges }

    func openSettings() { route = .settings }
    func openPermissions() {
        scrollAnchor = "permissions"
        route = .settings
    }
    func openRemoteControl() {
        scrollAnchor = "remote-control"
        route = .settings
    }
    func openConfigEditor() { route = .configEditor }
    func openAIEditor() { route = .aiEditor }
    func openPairing() { route = .pairing }
    func openTailscaleGuide() { route = .tailscaleGuide }
    func openChangelog() { route = .changelog }

    @discardableResult
    func goBack() -> Bool {
        guard route != .settings else { return false }
        route = .settings
        return true
    }

    func prepareConfigDraft() {
        guard !configDraft.hasChanges else { return }
        do {
            let source = try Self.readSource()
            configDraft.load(text: source, source: source)
            configError = nil
        } catch {
            configError = "Could not read config.json: \(error.localizedDescription)"
        }
    }

    func prepareAIDraft() {
        guard !aiDraft.hasChanges else { return }
        do {
            let source = try Self.readSource()
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(source.utf8))
            aiDraft.load(text: config.aiInstructions ?? "", source: source)
            aiError = nil
        } catch {
            aiError = "Could not read AI instructions: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveConfig(store: UsageStore) -> Bool {
        do {
            try configDraft.checkSource(Self.readSource())
            try ConfigLoader.saveRaw(configDraft.text)
            configDraft.didSave(text: configDraft.text, source: try Self.readSource())
            configError = nil
            configSaved = true
            store.reloadConfig()
            return true
        } catch {
            configError = "Could not save config.json: \(error.localizedDescription)"
            configSaved = false
            return false
        }
    }

    @discardableResult
    func saveAI(store: UsageStore) -> Bool {
        do {
            let source = try Self.readSource()
            try aiDraft.checkSource(source)
            var config = try JSONDecoder().decode(AppConfig.self, from: Data(source.utf8))
            let trimmed = aiDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            config.aiInstructions = trimmed.isEmpty ? nil : trimmed
            try ConfigLoader.validate(config)
            try ConfigLoader.save(config)
            aiDraft.didSave(text: trimmed, source: try Self.readSource())
            aiError = nil
            aiSaved = true
            store.reloadConfig()
            store.refreshAIInsight(for: store.snapshots)
            return true
        } catch {
            aiError = "Could not save AI instructions: \(error.localizedDescription)"
            aiSaved = false
            return false
        }
    }

    func discardConfigDraft() {
        configDraft = SettingsTextDraft()
        configSaved = false
        prepareConfigDraft()
    }

    func discardAIDraft() {
        aiDraft = SettingsTextDraft()
        aiSaved = false
        prepareAIDraft()
    }

    func discardDrafts() {
        configDraft = SettingsTextDraft()
        aiDraft = SettingsTextDraft()
        configError = nil
        aiError = nil
        configSaved = false
        aiSaved = false
    }

    /// Both editors write the same file. Requiring an explicit resolution prevents a
    /// quit-time Save from silently choosing which draft's AI instructions should win.
    func saveDrafts(store: UsageStore) -> Bool {
        if configDraft.hasChanges && aiDraft.hasChanges {
            configError = "Both editors have unsaved changes to config.json. Save one draft, then review the other before quitting."
            openConfigEditor()
            return false
        }
        if configDraft.hasChanges, !saveConfig(store: store) {
            openConfigEditor()
            return false
        }
        if aiDraft.hasChanges, !saveAI(store: store) {
            openAIEditor()
            return false
        }
        return true
    }

    private static func readSource() throws -> String {
        do {
            return try String(contentsOfFile: ConfigLoader.path, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }
}
