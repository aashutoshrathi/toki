import SwiftUI

struct ActiveAgentsPanel: View {
    @ObservedObject var store: UsageStore
    @State private var pendingTermination: ActiveAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active agents")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                // Shows that it is working and refuses a second press while it is.
                //
                // The scan is not instant, and the button previously looked identical before,
                // during and after a refresh - so a press that was already running read as a
                // press that had done nothing, and invited another. The store drops overlapping
                // scans anyway, so those extra presses were silently discarded.
                Button {
                    store.refreshActiveAgents()
                } label: {
                    if store.isScanningAgents {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isScanningAgents)
                .frame(width: 16, height: 16)
                .pointerOnHover()
                .help(store.isScanningAgents ? "Scanning for agents…" : "Refresh active agents")
                .accessibilityLabel(store.isScanningAgents ? "Scanning for agents" : "Refresh active agents")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.activeAgents.isEmpty {
                        EmptyPanel(
                            systemImage: "terminal",
                            title: "No active agents",
                            detail: "Supported coding-agent sessions appear here while they are running."
                        )
                    } else {
                        ForEach(store.activeAgents) { agent in
                            HStack(spacing: 6) {
                                Button {
                                    ActiveAgentNavigator.navigate(to: agent)
                                } label: {
                                    HStack(spacing: 8) {
                                        ProviderLogo(provider: agent.provider, size: 18)
                                            // Dot rides on the provider logo so the row's layout
                                            // doesn't shift when an agent starts or stops waiting.
                                            .overlay(alignment: .topTrailing) {
                                                if agent.needsInput {
                                                    Circle()
                                                        .fill(Color.red)
                                                        .frame(width: 7, height: 7)
                                                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                                                        .offset(x: 2, y: -2)
                                                }
                                            }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(agent.title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .lineLimit(1)
                                            if let attention = agent.attention {
                                                Text(attention.summary)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Color.red)
                                                    .lineLimit(2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            if let dir = agent.directoryDisplay {
                                                Text(dir)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            Text(agentDetail(agent))
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                            if let usageLine = agent.sessionUsage?.displayLine {
                                                Text(usageLine)
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: agent.hasTerminalTarget ? "arrow.up.forward.app" : "macwindow.on.rectangle")
                                            .foregroundStyle(Color.blue)
                                    }
                                    // Fill the row (minus the quit button) so the whole card area is
                                    // tappable for navigation even though its label no longer owns
                                    // the background.
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(agent.attention.map { "\($0.summary) - click to go answer" }
                                    ?? (agent.hasTerminalTarget ? "Go to this terminal session" : "Open the likely host app"))

                                // Quit button, folded inside the card next to the open affordance
                                // (a sibling of the navigate button, not nested in it, so clicking
                                // it never also triggers navigation).
                                Button {
                                    pendingTermination = agent
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Quit this agent")
                                .accessibilityLabel("Quit this agent")
                                .pointerOnHover()
                            }
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .frame(maxHeight: accountListHeight())
        .confirmationDialog(
            "Quit \(pendingTermination?.title ?? "this agent")?",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                if let agent = pendingTermination {
                    store.terminateAgent(agent)
                }
                pendingTermination = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTermination = nil
            }
        } message: {
            Text("Sends a terminate signal to PID \(pendingTermination?.processID ?? 0). Any unsaved progress in that session may be lost.")
        }
    }

    private func agentDetail(_ agent: ActiveAgent) -> String {
        let host = agent.hostApp?.displayName ?? (agent.hasTerminalTarget ? "Terminal" : "Editor or background")
        return "\(host) • \(agent.memoryDisplay) • Click to open"
    }
}
