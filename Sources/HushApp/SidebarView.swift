import SwiftUI
import HushKit
import MuesliCore

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var selection: Set<Route>

    var body: some View {
        List(selection: $selection) {
            if state.searchHits == nil {
                Section {
                    Label("Home", systemImage: "house").tag(Route.home)
                    Label {
                        HStack {
                            Text("Action items")
                            Spacer()
                            if !state.openTasks.isEmpty {
                                Text("\(state.openTasks.count)").font(DesignTokens.small.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    } icon: { Image(systemName: "checklist") }.tag(Route.tasks)
                }
            }
            if state.searchHits != nil {
                Section(state.filteredMeetings.isEmpty ? "No matches" : "\(state.filteredMeetings.count) \(state.filteredMeetings.count == 1 ? "match" : "matches")") {
                    ForEach(state.filteredMeetings) { meeting in row(meeting) }
                }
            } else if state.meetings.isEmpty {
                Section("Meetings") {
                    Text("Your meetings will appear here.").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).selectionDisabled()
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) { ForEach(group.meetings) { meeting in row(meeting) } }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .contextMenu(forSelectionType: Route.self) { items in
            let ids = items.compactMap { if case .meeting(let id) = $0 { id } else { nil } }
            if !ids.isEmpty {
                if ids.count == 1, let id = ids.first {
                    Button("Open") { state.select(id) }
                    Button("Copy notes") { Task { await copyNotes(id) } }
                    Button("Show in Finder") { state.revealFolder(id) }.disabled(state.isDemo)
                    Divider()
                }
                Button(ids.count == 1 ? "Delete…" : "Delete \(ids.count) meetings…", role: .destructive) { state.delete(ids) }
                    .disabled(!ids.contains(where: state.canDelete))
            }
        } primaryAction: { items in
            if let first = items.first { state.go(first) }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        MeetingRow(meeting: meeting, state: state, snippet: state.snippet(for: meeting.id)).tag(Route.meeting(meeting.id))
    }

    private var footer: some View {
        VStack(spacing: DesignTokens.space) {
            if state.capture.isRecording, let current = state.current {
                Button { state.select(current.id) } label: {
                    HStack(spacing: DesignTokens.space) {
                        RecordingDot(size: 8)
                        Text("Recording").font(DesignTokens.chromeStrong)
                        Spacer()
                        Text(Transcript.timestamp(state.elapsed)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                    }
                }.buttonStyle(.hushSecondary)
            } else {
                Button { state.start() } label: {
                    HStack(spacing: DesignTokens.space) {
                        Circle().fill(DesignTokens.ember).frame(width: 9, height: 9)
                        Text(state.isStarting || state.capture.isPreparing ? (state.capture.progressText.isEmpty ? "Getting ready…" : state.capture.progressText) : "Start recording")
                            .font(DesignTokens.chromeStrong).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                        ViewThatFits { KeyHint("⌘N"); EmptyView() }
                    }
                }
                .buttonStyle(HushButtonStyle(kind: .secondary, large: true, fullWidth: true))
                .disabled(!state.canRecord)
            }
            HStack(spacing: 5) {
                Image(systemName: state.preferences.providers.leavesMac ? "arrow.up.forward.circle" : "lock")
                Text(state.preferences.providers.leavesMac ? state.preferences.providers.privacyLabel : "Everything stays on this Mac")
            }
            .font(DesignTokens.small).foregroundStyle(DesignTokens.faint).frame(maxWidth: .infinity)
            .onTapGesture { state.showSettings?(.models) }
            .help(state.preferences.providers.dataFlow)
        }
        .padding(DesignTokens.gap)
        .background(.bar)
    }

    private func copyNotes(_ id: UUID) async {
        let text = state.selectedID == id ? state.markdown : ((try? await state.store?.markdown(id)) ?? "")
        guard !text.isEmpty, let meeting = state.meeting(id) else { return }
        state.copy(Exporter.cleanMarkdown(text, meeting: meeting)); state.show(.success, "Notes copied")
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Meeting]] = [:]
        for meeting in state.meetings {
            let date = meeting.startedAt
            let title: String
            if calendar.isDateInToday(date) { title = "Today" }
            else if calendar.isDateInYesterday(date) { title = "Yesterday" }
            else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day, days < 7 { title = "This week" }
            else if calendar.isDate(date, equalTo: .now, toGranularity: .month) { title = "Earlier this month" }
            else { title = date.formatted(.dateTime.month(.wide).year()) }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(meeting)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let state: AppState
    var snippet: String?
    /// Hierarchical styles only: the list swaps them for selected-text colours on the accent background.
    /// Fixed colours would stay dark on a dark selection.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meeting.title).font(DesignTokens.chromeStrong).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 4)
                MeetingStatusMark(meeting: meeting, state: state)
            }
            HStack(spacing: 4) {
                Text(meeting.startedAt.relativeDay == "Today" || meeting.startedAt.relativeDay == "Yesterday"
                     ? meeting.startedAt.formatted(date: .omitted, time: .shortened)
                     : meeting.startedAt.formatted(.dateTime.month(.abbreviated).day()))
                if meeting.endedAt != nil { Text("·"); Text(meeting.duration.spoken) }
            }
            .font(DesignTokens.small.monospacedDigit()).foregroundStyle(.secondary)
            if let snippet, !snippet.isEmpty {
                HighlightedText(text: snippet).font(DesignTokens.small).foregroundStyle(.secondary)
            } else if let preview = meeting.preview {
                Text(preview).font(DesignTokens.small).foregroundStyle(.tertiary).lineLimit(2)
            } else if meeting.state == .failed {
                Text("Needs attention").font(DesignTokens.small.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
