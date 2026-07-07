import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            overview
            if let configError = store.configError {
                ErrorBanner(message: configError)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.snapshots) { snapshot in
                            AccountCard(snapshot: snapshot, store: store) { id in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                }
                            }
                            .id(snapshot.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.trailing, 2)
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.snapshots.map(\.id))
                }
                .frame(maxHeight: accountListHeight())
            }

            if store.debugMode {
                debugPanel
            }
        }
        .padding(12)
        .frame(width: popoverWidth(), height: popoverHeight(), alignment: .top)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            TokiLogoMark(size: 34)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("/toki")
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    Text("v\(appVersion)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .onTapGesture(count: 5) {
                            store.toggleDebug()
                        }
                }
            }
            Spacer()
            headerControls
        }
    }

    private var headerControls: some View {
        HStack(spacing: 5) {
            Button {
                store.refresh(minimumRefreshInterval: 60)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Refresh")
            .pointerOnHover()

            Button {
                ConfigLoader.openInDefaultEditor()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Open config")
            .pointerOnHover()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 25, height: 25)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.red.opacity(0.42), lineWidth: 1)
            )
            .help("Quit")
            .pointerOnHover()
        }
    }

    private var overview: some View {
        HStack(spacing: 8) {
            StatBlock(title: "Accounts", value: "\(store.snapshots.count)", systemImage: "person.2")
            StatBlock(title: "Lowest", value: lowestRemainingText, systemImage: "gauge.with.dots.needle.bottom.50percent")
        }
    }

    private var lowestRemainingText: String {
        guard let ratio = store.snapshots.compactMap(\.remainingRatio).min() else { return "--" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "ant.fill")
                    .foregroundStyle(.orange)
                Text("Debug")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Clear") {
                    store.debugLog.removeAll()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .pointerOnHover()
            }
            if store.debugLog.isEmpty {
                Text("No log entries")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.debugLog) { entry in
                            HStack(spacing: 6) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
