import SwiftUI
import HushKit
import MuesliCore

/// The notebook's front page: start a recording, what's next, what's open, what's recent.
struct HomeView: View {
    @Bindable var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.margin - 8) {
                greeting
                startCard
                if state.preferences.calendarEnabled { upcoming } else if !state.isDemo { calendarPrompt }
                if !state.openTasks.isEmpty { openItems }
                recent
            }
            .frame(maxWidth: DesignTokens.pageWidth, alignment: .leading)
            .padding(.horizontal, DesignTokens.margin).padding(.top, DesignTokens.margin).padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .background(DesignTokens.paper)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.salutation()).font(DesignTokens.display)
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()) + summaryLine)
                .font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
        }
    }
    private var summaryLine: String {
        let today = state.meetings.filter { Calendar.current.isDateInToday($0.startedAt) }.count
        let upcoming = state.preferences.calendarEnabled ? state.calendar.meetings.filter { Calendar.current.isDateInToday($0.start) && $0.start > .now }.count : 0
        var parts: [String] = []
        if today > 0 { parts.append("\(today) recorded today") }
        if upcoming > 0 { parts.append("\(upcoming) still to come") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")
    }
    static func salutation(at date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello"
        }
    }

    private var startCard: some View {
        Card(padding: DesignTokens.block - 4) {
            HStack(alignment: .center, spacing: DesignTokens.inset) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.capture.isRecording ? "You're recording" : "Start a recording").font(DesignTokens.heading)
                    Text(state.capture.isRecording ? "Hush is listening to both sides of the conversation." : "Hush listens to you and the call on separate tracks, then writes the notes.")
                        .font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignTokens.space) { languageAndShortcut }
                        VStack(alignment: .leading, spacing: 6) { languageAndShortcut }
                    }.padding(.top, 6)
                }
                Spacer()
                if state.capture.isRecording, let current = state.current {
                    Button { state.select(current.id) } label: {
                        HStack(spacing: 8) { RecordingDot(size: 8); Text(Transcript.timestamp(state.elapsed)).monospacedDigit() }
                    }.buttonStyle(HushButtonStyle(kind: .secondary, large: true))
                } else {
                    Button { state.start() } label: {
                        HStack(spacing: 8) { Circle().fill(.white).frame(width: 8, height: 8); Text(state.isStarting ? "Starting…" : "Record") }
                    }
                    .buttonStyle(HushButtonStyle(kind: .record, large: true)).disabled(!state.canRecord)
                }
            }
        }
    }

    @ViewBuilder private var languageAndShortcut: some View {
        LanguagePicker(locale: $state.preferences.locale, locales: state.locales).labelsHidden().fixedSize()
            .disabled(state.capture.isRecording)
        if state.preferences.globalShortcut { HStack(spacing: 4) { Text("From anywhere").foregroundStyle(DesignTokens.faint); KeyHint("⌃⌥⌘R") }.font(DesignTokens.small) }
    }

    private var upcoming: some View {
        let events = state.calendar.meetings.filter { $0.end > .now }.prefix(4)
        return VStack(alignment: .leading, spacing: DesignTokens.gap) {
            SectionLabel("Coming up")
            if events.isEmpty {
                Text("Nothing on your calendar for the next few days.").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            if index > 0 { Divider().padding(.leading, DesignTokens.inset) }
                            UpcomingRow(state: state, event: event)
                        }
                    }
                }
            }
        }
    }

    private var calendarPrompt: some View {
        Card {
            HStack(spacing: DesignTokens.inset) {
                Image(systemName: "calendar").font(.system(size: 20)).foregroundStyle(DesignTokens.soft)
                VStack(alignment: .leading, spacing: 3) {
                    Text("See your meetings here").font(DesignTokens.chromeStrong)
                    Text("Connect Calendar and Hush taps you a minute before each call. Read-only, no extra sign-in.")
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Connect Calendar") { state.enableCalendar() }.buttonStyle(.hushSecondary)
            }
        }
    }

    private var openItems: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack {
                SectionLabel("Open action items")
                Spacer()
                Button("See all \(state.openTasks.count)") { state.go(.tasks) }.buttonStyle(.plain).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }
            Card {
                VStack(alignment: .leading, spacing: DesignTokens.gap) {
                    ForEach(state.openTasks.prefix(5)) { task in
                        TaskRow(text: task.text, done: task.done, meetingTitle: state.meeting(task.meetingID)?.title) { state.toggleTask(task) }
                    }
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            SectionLabel("Recent")
            if state.meetings.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: DesignTokens.space) {
                        Text("Your first meeting is one click away.").font(DesignTokens.chromeStrong)
                        Text("Press Record when a call starts. Wear headphones so your voice and theirs stay on separate tracks. Notes appear a few moments after you stop.")
                            .font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(state.meetings.prefix(6).enumerated()), id: \.element.id) { index, meeting in
                            if index > 0 { Divider().padding(.leading, DesignTokens.inset) }
                            RecentRow(meeting: meeting, state: state)
                        }
                    }
                }
            }
        }
    }
}

struct UpcomingRow: View {
    @Bindable var state: AppState
    let event: CalendarMeeting
    var compact = false
    var body: some View {
        HStack(spacing: DesignTokens.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.start.formatted(date: .omitted, time: .shortened)).font(DesignTokens.chromeStrong.monospacedDigit())
                Text(event.start.relativeDay).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }.frame(width: compact ? 62 : 72, alignment: .leading)
            Rectangle().fill(event.isHappeningNow ? DesignTokens.ember : DesignTokens.hairline).frame(width: 2, height: 30).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(DesignTokens.chrome).lineLimit(1)
                Text(detail).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).lineLimit(1)
            }
            Spacer(minLength: DesignTokens.space)
            if !compact {
                Menu {
                    Button("Follow settings") { state.autoOverrides.removeValue(forKey: event.id) }
                    Button("Record automatically") { state.autoOverrides[event.id] = true }
                    Button("Ask first") { state.autoOverrides[event.id] = false }
                } label: {
                    Text((state.autoOverrides[event.id] ?? state.preferences.autoRecord) ? "Auto" : "Ask").font(DesignTokens.small)
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(DesignTokens.soft)
                .help("Whether Hush starts recording by itself when this meeting begins")
            }
            if event.isRecordableNow || !compact {
                Button(event.joinURL != nil ? "Join & record" : "Record") {
                    if event.joinURL != nil { state.join(event) } else { state.start(event: event) }
                }
                .buttonStyle(HushButtonStyle(kind: event.isRecordableNow ? .primary : .secondary)).controlSize(.small)
                .disabled(!state.canRecord)
            }
        }
        .padding(.horizontal, compact ? 0 : DesignTokens.inset).padding(.vertical, 10)
    }
    private var detail: String {
        var parts: [String] = []
        if event.isHappeningNow { parts.append("Now") }
        else if event.start.timeIntervalSinceNow < 3600 { parts.append("In \(max(1, Int(event.start.timeIntervalSinceNow / 60))) min") }
        else { parts.append(event.end.timeIntervalSince(event.start).spoken) }
        if !event.attendees.isEmpty { parts.append(event.attendees.prefix(2).joined(separator: ", ") + (event.attendees.count > 2 ? " +\(event.attendees.count - 2)" : "")) }
        if let host = event.joinURL?.host() { parts.append(host.replacingOccurrences(of: "www.", with: "")) }
        return parts.joined(separator: " · ")
    }
}

struct RecentRow: View {
    let meeting: Meeting
    let state: AppState
    @State private var hovering = false
    var body: some View {
        Button { state.select(meeting.id) } label: {
            HStack(alignment: .top, spacing: DesignTokens.gap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(meeting.title).font(DesignTokens.chromeStrong).lineLimit(1)
                        MeetingStatusMark(meeting: meeting, state: state)
                    }
                    if let preview = meeting.preview {
                        Text(preview).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: DesignTokens.gap)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(meeting.startedAt.relativeDay).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    if meeting.endedAt != nil { Text(meeting.duration.spoken).font(DesignTokens.small.monospacedDigit()).foregroundStyle(DesignTokens.faint) }
                }
            }
            .padding(.horizontal, DesignTokens.inset).padding(.vertical, DesignTokens.gap)
            .background(hovering ? DesignTokens.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// Every checklist line across meetings.
struct ActionItemsView: View {
    @Bindable var state: AppState
    @State private var filter = 0
    private var shown: [NoteTask] { filter == 0 ? state.tasks.filter { !$0.done } : filter == 1 ? state.tasks.filter(\.done) : state.tasks }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.block) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Action items").font(DesignTokens.display)
                        Text(state.openTasks.isEmpty ? "Nothing open." : "\(state.openTasks.count) open across \(Set(state.openTasks.map(\.meetingID)).count) meetings")
                            .font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
                    }
                    Spacer()
                    Picker("Show", selection: $filter) { Text("Open").tag(0); Text("Done").tag(1); Text("All").tag(2) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if shown.isEmpty {
                    Text(filter == 1 ? "Checked items appear here." : "When notes include action items, they collect here so nothing slips.")
                        .font(DesignTokens.body).foregroundStyle(DesignTokens.soft).padding(.top, DesignTokens.block)
                }
                ForEach(groups, id: \.0) { id, items in
                    if let meeting = state.meeting(id) {
                        VStack(alignment: .leading, spacing: DesignTokens.gap) {
                            Button { state.select(id) } label: {
                                HStack(spacing: 6) {
                                    Text(meeting.title).font(DesignTokens.section)
                                    Text(meeting.startedAt.relativeDay).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(DesignTokens.faint)
                                }
                            }.buttonStyle(.plain)
                            Card {
                                VStack(alignment: .leading, spacing: DesignTokens.gap) {
                                    ForEach(items) { task in
                                        TaskRow(text: task.text, done: task.done) { state.toggleTask(task) }
                                            .contextMenu {
                                                Button("Copy") { state.copy(NoteParser.taskParts(task.text).title) }
                                                Button("Add to Reminders") { state.addToReminders([task]) }.disabled(state.isDemo)
                                                Button("Open meeting") { state.select(id) }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: DesignTokens.pageWidth, alignment: .leading)
            .padding(.horizontal, DesignTokens.margin).padding(.top, DesignTokens.margin).padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .background(DesignTokens.paper)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar {
            ToolbarItem {
                Button { state.addToReminders(state.openTasks) } label: { Label("Add open items to Reminders", systemImage: "checklist.checked") }
                    .disabled(state.openTasks.isEmpty || state.isDemo).help("Add every open item to Reminders")
            }
        }
    }
    private var groups: [(UUID, [NoteTask])] {
        var order: [UUID] = []
        var buckets: [UUID: [NoteTask]] = [:]
        for task in shown { if buckets[task.meetingID] == nil { order.append(task.meetingID) }; buckets[task.meetingID, default: []].append(task) }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
