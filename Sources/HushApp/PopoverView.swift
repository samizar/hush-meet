import SwiftUI
import HushKit
import MuesliCore

struct PopoverView: View {
    @Bindable var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            HStack {
                Text("hush").font(DesignTokens.title)
                Spacer()
                Button { state.showSettings?() } label: { Image(systemName: "gearshape").foregroundStyle(DesignTokens.soft) }.buttonStyle(.plain).help("Settings")
            }
            if state.capture.isRecording { recording }
            else if state.capture.isPreparing {
                Text(state.capture.progressText).font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
                ProgressView().progressViewStyle(.linear).tint(DesignTokens.soft)
            } else if state.busy {
                Text(state.current?.state == .transcribing ? "Finishing the transcript…" : "Writing notes…").font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
                ProgressView().progressViewStyle(.linear).tint(DesignTokens.soft)
            } else { idle }
            Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
            if let updater = state.updater, updater.updateAvailable {
                Button("Update available…") { updater.checkForUpdates() }
                    .buttonStyle(.plain).font(DesignTokens.chrome)
                    .disabled(!updater.canCheck || state.preventsUpdateRestart)
            }
            HStack {
                Button("Open notebook") { state.showMain?() }.buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(DesignTokens.soft)
            }.font(DesignTokens.chrome)
        }.padding(DesignTokens.inset).frame(width: DesignTokens.popoverWidth)
            .foregroundStyle(DesignTokens.ink).font(DesignTokens.chrome).tint(DesignTokens.ink)
    }
    private var recording: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            HStack {
                Text("Listening.").font(DesignTokens.body)
                Spacer(); Text(Transcript.timestamp(state.elapsed)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
            }
            LiveLine(capture: state.capture)
            TextField("A thought to keep…", text: Binding(get: { state.current?.userNotes ?? state.liveNotes }, set: { text in
                if let id = state.currentID { state.setSideNotes(id, text: text) }
            }), axis: .vertical).textFieldStyle(.plain)
                .font(DesignTokens.body).lineLimit(3...6).accessibilityLabel("Meeting notes")
            LiveTranscript(capture: state.capture).lineLimit(3)
            if let warning = state.capture.warning { Text(warning).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
            if state.preferences.providers.leavesMac { Text(state.preferences.providers.dataFlow).font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
            Button { state.stop() } label: { HStack { Image(systemName: "stop.fill"); Text("Stop"); Spacer() } }
                .buttonStyle(QuietButtonStyle(prominent: true, recording: true))
        }
    }
    private var idle: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            if state.preferences.calendarEnabled, let event = state.calendar.meetings.first {
                Text("NEXT UP").font(DesignTokens.small).foregroundStyle(DesignTokens.soft).tracking(DesignTokens.divider)
                Text(event.title).font(DesignTokens.body).lineLimit(2)
                HStack {
                    Text(event.start, format: .dateTime.weekday(.abbreviated).hour().minute()).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                    Spacer()
                    Button("Record") { state.start(event: event) }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(!state.canRecord)
                }
            } else {
                Text("Ready when you are.").font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
                Button("Record a meeting") { state.start() }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(!state.canRecord)
            }
            LanguagePicker(locale: $state.preferences.locale, locales: state.locales).labelsHidden().padding(.bottom, DesignTokens.space)
            let today = state.meetings.filter { Calendar.current.isDateInToday($0.startedAt) }
            if !today.isEmpty {
                Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
                Text("TODAY").font(DesignTokens.small).foregroundStyle(DesignTokens.soft).tracking(DesignTokens.divider)
                ForEach(today.prefix(5)) { meeting in
                    Button {
                        state.select(meeting.id); state.showMain?()
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: DesignTokens.smallGap) {
                                Text(meeting.title).font(DesignTokens.body).lineLimit(1)
                                Text(meeting.startedAt, format: .dateTime.hour().minute()).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                            }
                            Spacer(); Text(Transcript.timestamp(meeting.duration)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                        }
                    }.buttonStyle(.plain).padding(.vertical, DesignTokens.smallGap)
                }
            }
            if let notice = state.notice { Text(notice).font(DesignTokens.small).foregroundStyle(DesignTokens.soft).lineLimit(4) }
        }
    }
}

struct MeetingCardView: View {
    var state: AppState
    var event: CalendarMeeting?
    var app: String?
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            Text(event?.title ?? "A conversation in \(app ?? "progress")").font(DesignTokens.body).lineLimit(2)
            Text(event == nil ? "Keep the good parts?" : event!.start > .now ? "Starts in 1 min" : "Your meeting is starting")
                .font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
            HStack(spacing: DesignTokens.space) {
                Button("Record") { state.start(event: event) }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(!state.canRecord)
                Button("Skip") { state.skip(event) }.buttonStyle(QuietButtonStyle())
            }
        }.padding(DesignTokens.inset).frame(width: DesignTokens.popoverWidth, alignment: .leading)
            .background(DesignTokens.paper).foregroundStyle(DesignTokens.ink)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.hairline, lineWidth: DesignTokens.divider))
    }
}
