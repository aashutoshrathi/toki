import SwiftUI

// Full-page wrapper for AIInstructionsEditor, reached from its row in Settings - kept as its
// own page rather than inline so the text editor doesn't crowd the rest of Settings.
struct AIInstructionsPage: View {
    @ObservedObject var store: UsageStore
    var onClose: () -> Void

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
                Text("AI instructions")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            AIInstructionsEditor(store: store)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// Editor for the on-device AI prompt (config's `aiInstructions`). Empty means the built-in
// default is used - shown as placeholder text. Saving persists and regenerates immediately.
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
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                Text("AI insight instructions")
                    .font(.system(size: 12, weight: .semibold))
            }
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
                    Text(defaultAIInstructions)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 10))
                    .frame(height: 110)
                    .padding(4)
                    .scrollContentBackground(.hidden)
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
        .padding(8)
        .background(Color.purple.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.purple.opacity(0.12), lineWidth: 1)
        )
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
