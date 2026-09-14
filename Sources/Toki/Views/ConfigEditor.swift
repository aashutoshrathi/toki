import SwiftUI

struct ConfigEditor: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var navigation: SettingsNavigationState
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if navigation.configDraft.hasChanges {
                Text("Unsaved changes • draft kept when you go back")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            JSONTextEditor(text: $navigation.configDraft.text)
                .disabled(navigation.configDraft.source == nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Configuration JSON")
            if let error = navigation.configError {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 72)
                if navigation.configDraft.source == nil {
                    Button("Retry reading configuration") { navigation.prepareConfigDraft() }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button(navigation.configSaved ? "Saved" : "Save") { navigation.saveConfig(store: store) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!navigation.configDraft.hasChanges)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Discard") { confirmingDiscard = true }
                    .disabled(!navigation.configDraft.hasChanges)
                Spacer()
            }
        }
        .onAppear { navigation.prepareConfigDraft() }
        .onChange(of: navigation.configDraft.text) {
            if navigation.configDraft.hasChanges { navigation.configSaved = false }
        }
        .confirmationDialog("Discard unsaved config changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { navigation.discardConfigDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reloads the current config.json. Your draft will be lost.")
        }
    }
}
