import SwiftUI

struct EventPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var presentation: EventPresentationState
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Pause Toki notifications", isOn: Binding(
                get: { store.preferences.dndEnabled },
                set: { store.setDND($0) }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 13))
            Text(store.preferences.dndEnabled
                 ? "Paused · Events are recorded without delivering notifications."
                 : "Active · Notifications follow your preferences and macOS permissions.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("Event type", selection: $presentation.filter) {
                    Text("All events").tag(nil as TokiEventKind?)
                    ForEach(EventPresentationState.kinds, id: \.self) { kind in
                        Text(EventPresentationState.label(for: kind)).tag(Optional(kind))
                    }
                }
                .font(.system(size: 11))
                Spacer()
                Button { confirmsClear = true } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(store.events.isEmpty)
                .help("Clear all event history")
                .accessibilityLabel("Clear all event history")
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.events.isEmpty {
                        EmptyPanel(systemImage: "bell.badge", title: "No events yet", detail: "Low quota, session, switch, and notification events appear here.")
                    } else if sections.isEmpty {
                        EmptyPanel(systemImage: "line.3.horizontal.decrease.circle", title: "No matching events", detail: "Choose All events to see the rest of your history.")
                    } else {
                        ForEach(sections, id: \.day) { section in
                            Text(EventPresentationState.dateLabel(section.day))
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.top, 4)
                            ForEach(section.events) { event in
                                eventRow(event).id(event.id.uuidString)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 2)
            }
            .scrollPosition(id: $presentation.scrollAnchor, anchor: .top)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: presentation.filter) { _, _ in presentation.scrollAnchor = nil }
        .alert("Clear all event history?", isPresented: $confirmsClear) {
            Button("Clear all history", role: .destructive) {
                store.clearEvents()
                presentation.expandedIDs.removeAll()
                presentation.scrollAnchor = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded event, including events hidden by the current filter. This can’t be undone.")
        }
    }

    private var sections: [(day: Date, events: [TokiEvent])] {
        EventPresentationState.sections(store.events, filter: presentation.filter)
    }

    private func eventRow(_ event: TokiEvent) -> some View {
        let isExpanded = presentation.expandedIDs.contains(event.id)
        return Button {
            if isExpanded { presentation.expandedIDs.remove(event.id) }
            else { presentation.expandedIDs.insert(event.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: event))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color(for: event))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(isExpanded ? nil : 2)
                    Text(event.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(event.timestamp, format: .dateTime.hour().minute())
                        if event.deliveredNotification {
                            Label("Delivered", systemImage: "bell.fill")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .contentSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide full event details")
    }

    private func icon(for event: TokiEvent) -> String {
        switch event.kind {
        case .lowQuota: return "exclamationmark.triangle.fill"
        case .recovered: return "checkmark.circle.fill"
        case .switchAccount: return "arrow.triangle.2.circlepath"
        case .session: return "timer"
        case .notification: return event.deliveredNotification ? "bell.fill" : "bell.slash"
        case .refresh: return "arrow.clockwise"
        case .reset: return "arrow.counterclockwise"
        case .serviceStatus: return "bolt.horizontal.circle.fill"
        }
    }

    private func color(for event: TokiEvent) -> Color {
        switch event.kind {
        case .lowQuota: return .orange
        case .recovered: return .green
        case .switchAccount: return .blue
        case .session: return .purple
        case .notification: return event.deliveredNotification ? .blue : .secondary
        case .refresh: return .secondary
        case .reset: return .teal
        case .serviceStatus: return .orange
        }
    }
}
