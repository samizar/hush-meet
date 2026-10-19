import SwiftUI
import HushKit
import MuesliCore

/// The menu bar popover: start, follow a recording, see what's next and what's recent.
struct PopoverView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, DesignTokens.inset).padding(.top, DesignTokens.inset).padding(.bottom, DesignTokens.gap)
            if !state.banners.isEmpty {
                BannerStack(state: state, compact: true).padding(.horizontal, DesignTokens.gap).padding(.bottom, DesignTokens.gap)
            }
            VStack(alignment: .leading, spacing: DesignTokens.inset) {
                if state.capture.isRecording { recording }
                else if state.capture.isPreparing || state.isStarting { preparing }
                else { idle }
                if let job = state.activeJob, let meeting = state.meeting(job), !state.capture.isRecording || job != state.currentID { processing(meeting) }
            }
            .padding(.horizontal, DesignTokens.inset).padding(.bottom, DesignTokens.inset)
            if !state.capture.isRecording && !recent.isEmpty {
                Divider()
                recentList.padding(.vertical, DesignTokens.space)
            }
            Divider()
            footer.padding(.horizontal, DesignTokens.space).padding(.vertical, 6)
        }
        .frame(width: DesignTokens.popoverWidth)
        .font(DesignTokens.chrome).foregroundStyle(DesignTokens.ink).tint(DesignTokens.ink)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.space) {
            Text("Hush").font(DesignTokens.heading)
            statusPill
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings") { state.showSettings?(nil) }
        }
    }
    @ViewBuilder private var statusPill: some View {
        if state.capture.isRecording {
            HStack(spacing: 5) { RecordingDot(size: 6); Text("Listening") }
                .font(DesignTokens.small.weight(.medium)).foregroundStyle(DesignTokens.ember)
                .padding(.horizontal, 7).padding(.vertical, 3).background(DesignTokens.emberWash, in: Capsule())
        } else if state.busy {
            Text("Writing notes").font(DesignTokens.small.weight(.medium)).foregroundStyle(DesignTokens.soft)
                .padding(.horizontal, 7).padding(.vertical, 3).background(DesignTokens.selected, in: Capsule())
        }
    }

    // MARK: States

    private var idle: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            if let event = state.nextMeeting, event.start.timeIntervalSinceNow < 12 * 3600 {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(event.isHappeningNow ? "Happening now" : "Next up")
                    UpcomingRow(state: state, event: event, compact: true)
                }
                .padding(.horizontal, DesignTokens.gap).padding(.vertical, DesignTokens.space)
                .background(DesignTokens.selected, in: RoundedRectangle(cornerRadius: DesignTokens.radius + 2))
            }
            Button { state.start() } label: {
                HStack(spacing: DesignTokens.space) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Start recording")
                    Spacer()
                    if state.preferences.globalShortcut { Text("⌃⌥⌘R").font(.system(size: 11, weight: .medium).monospaced()).opacity(0.75) }
                }
            }
            .buttonStyle(HushButtonStyle(kind: .record, large: true, fullWidth: true)).disabled(!state.canRecord)
            HStack {
                LanguagePicker(locale: $state.preferences.locale, locales: state.locales).labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Label(state.preferences.providers.leavesMac ? state.preferences.providers.privacyLabel : "On this Mac",
                      systemImage: state.preferences.providers.leavesMac ? "arrow.up.forward.circle" : "lock")
                    .font(DesignTokens.small).foregroundStyle(DesignTokens.faint).lineLimit(1)
            }
        }
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            Text(state.capture.progressText.isEmpty ? "Getting ready…" : state.capture.progressText).font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
            ProgressLine()
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.current?.title ?? "Recording").font(DesignTokens.chromeStrong).lineLimit(1)
                Spacer()
                Text(Transcript.timestamp(state.elapsed)).font(.system(size: 20, weight: .light).monospacedDigit())
            }
            LiveLine(capture: state.capture, height: 40, meName: state.current?.name(for: .me) ?? "Me", themName: state.current?.name(for: .them) ?? "Them")
            if let warning = state.capture.warning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(DesignTokens.amber)
                    Text(warning).font(DesignTokens.small).fixedSize(horizontal: false, vertical: true)
                }
                if let link = state.capture.settingsLink {
                    Button("Open System Settings") { NSWorkspace.shared.open(link) }.buttonStyle(.hushSecondary).controlSize(.small)
                }
            }
            TextField("A thought to keep…", text: Binding(get: { state.liveNotes }, set: { text in
                if let id = state.currentID { state.setSideNotes(id, text: text) }
            }), axis: .vertical)
                .textFieldStyle(.plain).font(DesignTokens.body).lineLimit(3...6)
                .padding(DesignTokens.space + 2)
                .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).strokeBorder(DesignTokens.hairline))
                .accessibilityLabel("Your notes for this meeting")
            LiveTranscript(capture: state.capture, meeting: state.current, limit: 2).lineLimit(3)
            HStack(spacing: DesignTokens.space) {
                Button { state.stop() } label: {
                    HStack(spacing: 6) { Image(systemName: "stop.fill").font(.system(size: 10)); Text("Stop") }.frame(maxWidth: .infinity)
                }.buttonStyle(HushButtonStyle(kind: .stop, large: true, fullWidth: true)).disabled(state.isStopping)
                Button { if let id = state.currentID { state.select(id) }; state.showMain?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(HushButtonStyle(kind: .secondary, large: true)).help("Open in the notebook")
            }
        }
    }

    private func processing(_ meeting: Meeting) -> some View {
        let progress = state.progress[meeting.id] ?? ProcessingProgress(phase: .waiting)
        return Button { state.select(meeting.id); state.showMain?() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(meeting.title).font(DesignTokens.chromeStrong).lineLimit(1)
                    Spacer()
                    if state.queue.count > 0 { Text("+\(state.queue.count) waiting").font(DesignTokens.small).foregroundStyle(DesignTokens.faint) }
                }
                Text(progress.title).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                ProgressLine(fraction: progress.fraction)
            }
            .padding(DesignTokens.gap)
            .background(DesignTokens.selected, in: RoundedRectangle(cornerRadius: DesignTokens.radius + 2))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: Recent

    private var recent: [Meeting] {
        state.meetings.filter { Calendar.current.isDate($0.startedAt, equalTo: .now, toGranularity: .weekOfYear) && $0.id != state.activeJob }.prefix(4).map { $0 }
    }
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Recent").padding(.horizontal, DesignTokens.inset).padding(.bottom, 4)
            ForEach(recent) { meeting in PopoverMeetingRow(meeting: meeting, state: state) }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { state.go(.home); state.showMain?() } label: { Label("Open Hush", systemImage: "book.closed") }
                .buttonStyle(.hushQuiet).keyboardShortcut("0")
            if !state.openTasks.isEmpty {
                Button { state.go(.tasks); state.showMain?() } label: { Label("\(state.openTasks.count) open", systemImage: "checklist") }
                    .buttonStyle(.hushQuiet)
            }
            Spacer()
            if let updater = state.updater, updater.updateAvailable {
                Button("Update…") { updater.checkForUpdates() }.buttonStyle(.hushQuiet)
                    .disabled(!updater.canCheck || state.preventsUpdateRestart)
            }
            Menu {
                Button("Settings…") { state.showSettings?(nil) }
                Button("Check for Updates…") { state.updater?.checkForUpdates() }
                    .disabled(state.updater?.canCheck != true || state.preventsUpdateRestart)
                Divider()
                Button("Quit Hush") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(DesignTokens.soft)
            .padding(.trailing, DesignTokens.space)
        }
    }
}

struct PopoverMeetingRow: View {
    let meeting: Meeting
    let state: AppState
    @State private var hovering = false
    var body: some View {
        Button { state.select(meeting.id); state.showMain?() } label: {
            HStack(spacing: DesignTokens.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) { Text(meeting.title).font(DesignTokens.chrome).lineLimit(1); MeetingStatusMark(meeting: meeting, state: state) }
                    Text(meeting.startedAt.relativeDay + " · " + meeting.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
                Spacer()
                if meeting.endedAt != nil { Text(meeting.duration.spoken).font(DesignTokens.small.monospacedDigit()).foregroundStyle(DesignTokens.faint) }
            }
            .padding(.horizontal, DesignTokens.inset).padding(.vertical, 6)
            .background(hovering ? DesignTokens.hover : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// The small card that slides down before a meeting or when a call starts. Never takes focus.
struct MeetingCardView: View {
    var state: AppState
    var event: CalendarMeeting?
    var app: String?
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack(alignment: .top, spacing: DesignTokens.gap) {
                Image(systemName: event == nil ? "phone.bubble" : "calendar").font(.system(size: 15)).foregroundStyle(DesignTokens.soft)
                    .frame(width: 30, height: 30).background(DesignTokens.selected, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event?.title ?? "Call in \(app ?? "progress")").font(DesignTokens.chromeStrong).lineLimit(2)
                    Text(subtitle).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DesignTokens.space) {
                if let event, event.joinURL != nil {
                    Button("Join & record") { state.join(event) }.buttonStyle(HushButtonStyle(kind: .primary)).disabled(!state.canRecord)
                    Button("Record") { state.start(event: event) }.buttonStyle(.hushSecondary).disabled(!state.canRecord)
                } else {
                    Button("Record") { state.start(event: event) }.buttonStyle(HushButtonStyle(kind: .primary)).disabled(!state.canRecord)
                }
                Spacer()
                Button("Not now") { state.skip(event) }.buttonStyle(.hushQuiet)
            }
        }
        .padding(DesignTokens.inset).frame(width: DesignTokens.popoverWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius + 2, style: .continuous).strokeBorder(DesignTokens.hairline))
        .foregroundStyle(DesignTokens.ink).tint(DesignTokens.ink)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .padding(16)
    }
    private var subtitle: String {
        guard let event else { return "Keep notes of this call?" }
        if event.start > .now { return "Starts in \(max(1, Int(event.start.timeIntervalSinceNow / 60))) min" + (event.attendees.isEmpty ? "" : " · " + event.attendees.prefix(2).joined(separator: ", ")) }
        return "Your meeting is starting"
    }
}
