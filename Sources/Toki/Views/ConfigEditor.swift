import SwiftUI

// In-app editor for the full config.json. Validates on save (rejecting invalid edits
// before they reach disk) and reloads the store so changes take effect immediately.
struct ConfigEditor: View {
    @ObservedObject var store: UsageStore

    @State private var text = ConfigLoader.rawContents()
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Config JSON")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    ConfigLoader.openInDefaultEditor()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help("Open in external editor")
                .pointerOnHover()
            }

            VStack(alignment: .leading, spacing: 6) {
                JSONTextEditor(text: $text)
                    .frame(height: 150)

                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                            .frame(width: 25, height: 25)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(saved ? "Saved" : "Save")
                    .accessibilityLabel(saved ? "Saved" : "Save")
                    .pointerOnHover()

                    Button {
                        text = ConfigLoader.rawContents()
                        error = nil
                        saved = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 25, height: 25)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Revert")
                    .accessibilityLabel("Revert")
                    .pointerOnHover()
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private func save() {
        do {
            try ConfigLoader.saveRaw(text)
            error = nil
            saved = true
            store.reloadConfig()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                saved = false
            }
        } catch {
            self.error = error.localizedDescription
            saved = false
        }
    }
}
