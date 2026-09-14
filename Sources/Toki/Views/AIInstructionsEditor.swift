import SwiftUI

struct AIInstructionsEditor: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var navigation: SettingsNavigationState
    @State private var confirmingDiscard = false
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steer how the on-device AI summarizes usage. Leave empty for the default.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !store.isAIInsightAvailable {
                Text("Apple Intelligence is unavailable. Instructions can be saved and will apply when it is enabled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(navigation.aiDraft.hasChanges ? "Unsaved changes • draft kept when you go back" : "Instructions saved in config.json")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if navigation.aiDraft.text.isEmpty {
                    ScrollView {
                        Text(defaultAIInstructions)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, PlainTextEditor.inset.width)
                            .padding(.vertical, PlainTextEditor.inset.height)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                PlainTextEditor(text: $navigation.aiDraft.text)
                    .disabled(navigation.aiDraft.source == nil)
                    .accessibilityLabel("AI instructions. Leave empty to use the default instructions.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if let error = navigation.aiError {
                ScrollView {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 72)
                if navigation.aiDraft.source == nil {
                    Button("Retry reading configuration") { navigation.prepareAIDraft() }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button(navigation.aiSaved ? "Saved" : "Save") { navigation.saveAI(store: store) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!navigation.aiDraft.hasChanges)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Discard") { confirmingDiscard = true }
                    .disabled(!navigation.aiDraft.hasChanges)
                Spacer(minLength: 0)
                Button("Use default") { confirmingReset = true }
                    .disabled(navigation.aiDraft.text.isEmpty)
            }
        }
        .onAppear { navigation.prepareAIDraft() }
        .onChange(of: navigation.aiDraft.text) {
            if navigation.aiDraft.hasChanges { navigation.aiSaved = false }
        }
        .confirmationDialog("Discard unsaved instructions?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { navigation.discardAIDraft() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This reloads the saved instructions. Your draft will be lost.")
        }
        .confirmationDialog("Replace this draft with the default?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Use default", role: .destructive) { navigation.aiDraft.text = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current draft will be cleared. Choose Save to apply the default instructions.")
        }
    }
}
