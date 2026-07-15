import SwiftUI

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
