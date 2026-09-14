import SwiftUI

struct ActiveAgentsPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: AccountPresentationState
    @State private var pendingTermination: ActiveAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active agents (\(store.activeAgents.count))")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    store.refreshActiveAgents()
                } label: {
                    Group {
                        if store.isScanningAgents {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isScanningAgents)
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
                        agentSection("Needs input", needsInput: true)
                        agentSection("Running", needsInput: false)
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 2)
            }
            .scrollPosition(id: $presentation.agentsScrollID)
        }
        .frame(maxHeight: .infinity)
        .onAppear { presentation.reconcileAgents(store.activeAgents) }
        .onChange(of: store.activeAgents.map(\.id)) { _, _ in
            presentation.reconcileAgents(store.activeAgents)
        }
        .confirmationDialog(
            "Quit \(pendingTermination?.title ?? "this agent")?",
            isPresented: Binding(
                get: { pendingTermination != nil },
                set: { if !$0 { pendingTermination = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                if let agent = pendingTermination { store.terminateAgent(agent) }
                pendingTermination = nil
            }
            Button("Cancel", role: .cancel) { pendingTermination = nil }
        } message: {
            Text("Sends a terminate signal to PID \(pendingTermination?.processID ?? 0). Any unsaved progress in that session may be lost.")
        }
    }

    @ViewBuilder
    private func agentSection(_ title: String, needsInput: Bool) -> some View {
        let agents = presentation.orderedAgents(store.activeAgents, needsInput: needsInput)
        if !agents.isEmpty {
            Text("\(title) (\(agents.count))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(needsInput ? Color.red : Color.secondary)
                .padding(.top, 4)
            ForEach(agents) { agent in
                agentRow(agent)
                    .id(agent.id)
            }
        }
    }

    private func agentRow(_ agent: ActiveAgent) -> some View {
        let identity = SessionIdentityPresentation(agent: agent, among: store.activeAgents)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                ActiveAgentNavigator.navigate(to: agent)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    ProviderLogo(provider: agent.provider, size: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(identity.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if let attention = agent.attention {
                            Text(attention.summary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let context = identity.context {
                            Text(context)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Text(identity.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let usageLine = agent.sessionUsage?.displayLine {
                            Text(usageLine)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: agent.hasTerminalTarget ? "arrow.up.forward.app" : "macwindow.on.rectangle")
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(agent.attention.map { "\($0.summary) — open to answer" }
                ?? (agent.hasTerminalTarget ? "Go to this terminal session" : "Open the likely host app"))
            .pointerOnHover()

            // A thread-store row has no independent process to terminate.
            if agent.canTerminate {
                Menu {
                    Button("Quit agent…", role: .destructive) { pendingTermination = agent }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Agent actions")
                .accessibilityLabel("Actions for " + identity.title)
                .frame(width: 28, height: 28)
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .contentSurface()
    }
}
