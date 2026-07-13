import SwiftUI

// Shown instead of the account list when there's no usable config.json yet. Scans for
// AI coding tools already installed/authenticated on the machine and lets the user add
// them with a single click, instead of hand-writing JSON.
struct OnboardingView: View {
    @ObservedObject var store: UsageStore
    var openConfigEditor: () -> Void

    private var connectable: [DetectedProvider] {
        store.addableProviders.filter(\.isConnectable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect an account")
                    .font(.system(size: 13, weight: .semibold))
                Text("Toki tracks usage locally - nothing leaves your machine.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if store.isScanningProviders {
                scanningRow
            } else if store.addableProviders.isEmpty {
                // Two different empty states: genuinely nothing signed in on this machine,
                // vs. everything detected is already connected (only reachable from the
                // "Add account" page, since onboarding's snapshots are always empty).
                // Telling someone with Claude Code already connected to "sign in to Claude
                // Code" would be actively wrong.
                if store.detectedProviders.isEmpty {
                    nothingDetected
                } else {
                    allConnected
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(store.addableProviders) { detected in
                        ProviderConnectRow(detected: detected) {
                            if let makeAccount = detected.makeAccount {
                                store.connect([makeAccount()])
                            }
                        }
                    }
                }

                if connectable.count > 1 {
                    Button {
                        store.connect(connectable.compactMap { $0.makeAccount?() })
                    } label: {
                        Label("Connect all detected", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointerOnHover()
                }
            }

            if let configError = store.configError {
                Text(configError)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Button {
                openConfigEditor()
            } label: {
                Text("Or edit config.json manually")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var scanningRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for Claude Code, Codex, OpenCode…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var nothingDetected: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing detected yet")
                .font(.system(size: 11, weight: .medium))
            Text("Sign in to Claude Code or Codex, then reopen this menu - Toki will pick them up automatically.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allConnected: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Everything detected is already connected")
                .font(.system(size: 11, weight: .medium))
            Text("Sign in to another provider, then reopen this menu - Toki will pick it up automatically.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderConnectRow: View {
    var detected: DetectedProvider
    var connect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProviderLogo(provider: detected.provider, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(detected.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detected.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if detected.isConnectable {
                Button("Connect", action: connect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerOnHover()
            } else {
                Text("Auto-detected")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
