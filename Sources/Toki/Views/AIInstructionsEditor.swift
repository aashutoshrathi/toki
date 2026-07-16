import SwiftUI

// Editor for the on-device AI prompt (config's `aiInstructions`), shown inline below its
// disclosure row in SettingsPanel - not its own page, so the title/chevron toggle it lives
// under doubles as this view's header. Empty means the built-in default is used, shown as
// placeholder text. Saving persists and regenerates immediately.
struct AIInstructionsEditor: View {
    @ObservedObject var store: UsageStore

    @State private var text: String
    @State private var saved = false
    @State private var error: String?

    init(store: UsageStore) {
        self.store = store
        _text = State(initialValue: store.aiInstructions ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steer how the on-device AI summarizes your usage. Leave empty for the default.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.isAIInsightAvailable {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("Apple Intelligence isn't available or enabled on this Mac. Your instructions are saved but won't generate insights until it is (System Settings \u{2192} Apple Intelligence & Siri).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange)
                .padding(6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    // Padding matches PlainTextEditor.inset exactly so the placeholder sits
                    // precisely where the real caret lands - a SwiftUI TextEditor's internal
                    // inset isn't public API, so this only lines up because both the editor
                    // and this overlay use the same explicit, known inset value.
                    Text(defaultAIInstructions)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, PlainTextEditor.inset.width)
                        .padding(.vertical, PlainTextEditor.inset.height)
                        .allowsHitTesting(false)
                }
                PlainTextEditor(text: $text, font: .systemFont(ofSize: 10))
                    .frame(height: 110)
            }
            .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.purple.opacity(0.18), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    persist(text)
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerOnHover()

                Button {
                    text = ""
                    persist("")
                } label: {
                    Label("Reset to default", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(text.isEmpty && store.aiInstructions == nil)
                .pointerOnHover()
            }
        }
    }

    private func persist(_ value: String) {
        if let failure = store.updateAIInstructions(value) {
            error = failure
            saved = false
            return
        }
        error = nil
        saved = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
        }
    }
}
