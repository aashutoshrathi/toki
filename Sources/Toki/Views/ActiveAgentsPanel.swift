import SwiftUI

struct ActiveAgentsPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active coding agents")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    store.refreshActiveAgents()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh active agents")
                .accessibilityLabel("Refresh active agents")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.activeAgents.isEmpty {
                        EmptyPanel(
                            systemImage: "terminal",
                            title: "No active agents",
                            detail: "Codex, Claude Code, Copilot CLI, and OpenCode sessions appear here."
                        )
                    } else {
                        ForEach(store.activeAgents) { agent in
                            Button {
                                ActiveAgentNavigator.navigate(to: agent)
                            } label: {
                                HStack(spacing: 8) {
                                    ProviderLogo(provider: agent.provider, size: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.title)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("PID \(agent.processID) • \(agent.runtime) • \(agent.surface)")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: agent.canNavigate ? "arrow.up.forward.app" : "app.dashed")
                                        .foregroundStyle(agent.canNavigate ? Color.blue : Color.secondary)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(agent.canNavigate ? "Go to this terminal session" : "Activate the likely host app")
                        }
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .frame(maxHeight: accountListHeight())
    }
}
