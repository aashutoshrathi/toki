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
                    .foregroundStyle(.red)
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

            // Second half of a first run: the permissions Toki would otherwise ask for one dialog
            // at a time, listed with what each one buys and nothing requested until it is. It can
            // be put away from here, and stays available in Settings afterwards.
            if !store.preferences.setupChecklistCompleted {
                Divider()
                    .padding(.vertical, 2)
                SetupChecklistView(store: store, mode: .firstRun, showsDismiss: true)
            }
        }
        .padding(10)
        .contentSurface()
    }

    private var scanningRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for supported coding agents and local usage…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var nothingDetected: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing detected yet")
                .font(.system(size: 11, weight: .medium))
            Text("Sign in to or use a supported coding agent, then reopen this menu - Toki will pick it up automatically.")
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
                    .background(.fill.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
