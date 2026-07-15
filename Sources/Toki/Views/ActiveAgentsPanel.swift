import SwiftUI

struct ActiveAgentsPanel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active agents")
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
                            detail: "Codex (terminal or inside ChatGPT), Claude Code, Copilot CLI, OpenCode, and Gemini sessions appear here."
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
                                            .lineLimit(1)
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
                                    }
                                    Spacer()
                                    Image(systemName: agent.hasTerminalTarget ? "arrow.up.forward.app" : "macwindow.on.rectangle")
                                        .foregroundStyle(Color.blue)
                                }
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(agent.hasTerminalTarget ? "Go to this terminal session" : "Open the likely host app")
                        }
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .frame(maxHeight: accountListHeight())
    }

    private func agentDetail(_ agent: ActiveAgent) -> String {
        let host = agent.hostApp?.displayName ?? (agent.hasTerminalTarget ? "Terminal" : "Editor or background")
        return "\(host) • Click to open"
    }
}
