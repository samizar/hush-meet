import SwiftUI
import HushKit
import MuesliCore

struct NotebookView: View {
    @Bindable var state: AppState
    var body: some View {
        HStack(spacing: .zero) {
            sidebar.frame(width: DesignTokens.sidebarWidth)
            Rectangle().fill(DesignTokens.hairline).frame(width: DesignTokens.divider)
            ZStack {
                DesignTokens.paper
                if let meeting = state.selected {
                    MeetingPage(state: state, meeting: meeting)
                } else { emptyPage }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(DesignTokens.chrome).foregroundStyle(DesignTokens.ink)
        .background(DesignTokens.paper)
        .frame(minWidth: DesignTokens.minWindowWidth, minHeight: DesignTokens.minWindowHeight)
        .onChange(of: state.search) { state.searchChanged() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: .zero) {
            HStack {
                Text("hush").font(DesignTokens.title)
                Spacer()
                Button { state.showSettings?() } label: { Image(systemName: "gearshape").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft) }
                    .buttonStyle(.plain).help("Settings")
            }.padding(.horizontal, DesignTokens.inset).padding(.top, DesignTokens.margin).padding(.bottom, DesignTokens.indent)
            HStack(spacing: DesignTokens.space) {
                Image(systemName: "magnifyingglass").foregroundStyle(DesignTokens.soft)
                TextField("Search your notebook", text: $state.search).textFieldStyle(.plain)
                    .accessibilityLabel("Search meeting titles, notes, and transcripts")
                if !state.search.isEmpty {
                    Button { state.search = "" } label: { Image(systemName: "xmark").foregroundStyle(DesignTokens.soft) }.buttonStyle(.plain)
                }
            }.padding(DesignTokens.gap).background(DesignTokens.paper, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                .padding(.horizontal, DesignTokens.gap).padding(.bottom, DesignTokens.inset)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.smallGap) {
                    if state.search.isEmpty && state.preferences.calendarEnabled && !state.calendar.meetings.isEmpty { upcoming }
                    if state.filteredMeetings.isEmpty {
                        Text(state.search.isEmpty ? "A little space for what matters." : "No matching meetings.")
                            .font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
                            .padding(DesignTokens.inset)
                    }
                    ForEach(grouped, id: \.0) { title, meetings in
                        Text(title.uppercased()).font(DesignTokens.small).tracking(DesignTokens.divider)
                            .foregroundStyle(DesignTokens.soft).padding(.horizontal, DesignTokens.inset)
                            .padding(.top, DesignTokens.gap).padding(.bottom, DesignTokens.space)
                        ForEach(meetings) { meeting in
                            Button { state.select(meeting.id) } label: {
                                VStack(alignment: .leading, spacing: DesignTokens.space) {
                                    Text(meeting.title).font(DesignTokens.body).lineLimit(2).multilineTextAlignment(.leading)
                                    HStack(spacing: DesignTokens.space) {
                                        Text(meeting.startedAt, format: .dateTime.hour().minute())
                                        Text("·")
                                        Text(Transcript.timestamp(meeting.duration))
                                        if meeting.state == .recording { Circle().fill(DesignTokens.ember).frame(width: DesignTokens.dot, height: DesignTokens.dot) }
                                    }.font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(DesignTokens.rowInset)
                                    .background(state.selectedID == meeting.id ? DesignTokens.selected : .clear, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                            }.buttonStyle(.plain).contextMenu {
                                Button("Delete meeting", role: .destructive) { state.delete(meeting.id) }.disabled(state.busy || state.capture.isRecording)
                            }
                        }
                    }
                }.padding(.horizontal, DesignTokens.space)
            }.defaultScrollAnchor(.top)
            Spacer(minLength: DesignTokens.space)
            VStack(spacing: DesignTokens.gap) {
                Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
                if state.capture.isRecording {
                    Button { state.stop() } label: {
                        HStack { Image(systemName: "stop.fill"); Text("Stop recording"); Spacer(); Text(Transcript.timestamp(state.elapsed)).font(DesignTokens.mono) }
                    }.buttonStyle(QuietButtonStyle(prominent: true, recording: true))
                } else {
                    Button { state.start() } label: {
                        HStack { Image(systemName: "circle"); Text(state.capture.isPreparing ? "Getting ready…" : "New meeting"); Spacer(); Text("⌘N").foregroundStyle(DesignTokens.soft) }
                    }.buttonStyle(QuietButtonStyle()).disabled(!state.canRecord).keyboardShortcut("n")
                }
                HStack(spacing: DesignTokens.smallGap) {
                    Image(systemName: state.preferences.providers.leavesMac ? "arrow.up.right" : "lock")
                    Text(state.preferences.providers.leavesMac ? "Using your chosen providers" : "Just you and your Mac")
                }.font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            }.padding(DesignTokens.rowInset)
        }.background(DesignTokens.sidebar)
    }
    private var upcoming: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            Text("COMING UP").font(DesignTokens.small).tracking(DesignTokens.divider).foregroundStyle(DesignTokens.soft)
            ForEach(state.calendar.meetings.prefix(3)) { event in
                VStack(alignment: .leading, spacing: DesignTokens.smallGap) {
                    HStack {
                        Text(event.title).font(DesignTokens.body).lineLimit(1)
                        Spacer()
                        Button { state.start(event: event) } label: { Image(systemName: "circle").font(DesignTokens.small) }
                            .buttonStyle(.plain).disabled(!state.canRecord).help("Record \(event.title)")
                    }
                    HStack {
                        Text(event.start, format: .dateTime.weekday(.abbreviated).hour().minute()).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                        Spacer()
                        Menu {
                            Button("Follow Settings") { state.autoOverrides.removeValue(forKey: event.id) }
                            Button("Record automatically") { state.autoOverrides[event.id] = true }
                            Button("Ask before recording") { state.autoOverrides[event.id] = false }
                        } label: { Text((state.autoOverrides[event.id] ?? state.preferences.autoRecord) ? "Auto" : "Ask").font(DesignTokens.small) }
                        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(DesignTokens.soft)
                    }
                }.padding(.vertical, DesignTokens.space)
            }
        }.padding(DesignTokens.gap).padding(.bottom, DesignTokens.gap)
    }
    private var grouped: [(String, [Meeting])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: state.filteredMeetings) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { date in
            let title = calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : date.formatted(.dateTime.month(.wide).day())
            return (title, groups[date] ?? [])
        }
    }
    private var emptyPage: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            Text("Be here.\nKeep the good parts.").font(DesignTokens.display).lineSpacing(DesignTokens.smallGap)
            Text("A quiet place for your conversations.\nRecord a meeting. Leave with clear notes.")
                .font(DesignTokens.body).foregroundStyle(DesignTokens.soft).lineSpacing(DesignTokens.noteLineSpacing)
            Button("Start a meeting") { state.start() }.buttonStyle(QuietButtonStyle(prominent: true)).disabled(!state.canRecord)
            if let notice = state.notice { Text(notice).font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).frame(maxWidth: DesignTokens.popoverWidth) }
        }.frame(maxWidth: DesignTokens.pageWidth, alignment: .leading).padding(DesignTokens.pageMargin)
    }
}

struct MeetingPage: View {
    @Bindable var state: AppState
    let meeting: Meeting
    @State private var editingTitle = false
    @State private var draftTitle = ""
    var body: some View {
        VStack(spacing: .zero) {
            HStack {
                Text("NOTEBOOK").font(DesignTokens.small).tracking(DesignTokens.divider).foregroundStyle(DesignTokens.soft)
                Spacer()
                if state.isDemo { Text("PREVIEW").font(DesignTokens.small).foregroundStyle(DesignTokens.soft) }
                Menu {
                    Button("Copy as Markdown") { state.copy(state.markdown) }.disabled(state.markdown.isEmpty)
                    Button("Save Markdown…") { Exporter.markdown(state.markdown, title: meeting.title) }.disabled(state.markdown.isEmpty)
                    Button("Save PDF…") { Exporter.pdf(state.markdown, meeting: meeting) }.disabled(state.markdown.isEmpty)
                    Divider()
                    Button("Copy transcript") { state.copy(state.displayedTranscript?.plainText() ?? "") }.disabled(state.displayedTranscript == nil)
                    Divider()
                    Button("Reveal meeting folder") { Task { if let folder = await state.store?.folder(meeting.id) { NSWorkspace.shared.activateFileViewerSelecting([folder]) } } }.disabled(state.isDemo)
                    Button("Delete meeting…", role: .destructive) { state.delete(meeting.id) }.disabled(state.busy || state.capture.isRecording)
                } label: { Label("Export", systemImage: "square.and.arrow.up").font(DesignTokens.chrome) }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(DesignTokens.soft)
            }.padding(.horizontal, DesignTokens.margin).padding(.top, DesignTokens.inset).padding(.bottom, DesignTokens.gap)
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.indent) {
                    VStack(alignment: .leading, spacing: DesignTokens.gap) {
                        if editingTitle {
                            TextField("Meeting title", text: $draftTitle).font(DesignTokens.title).textFieldStyle(.plain)
                                .onSubmit { state.rename(meeting.id, title: draftTitle); editingTitle = false }
                        } else {
                            Text(meeting.title).font(DesignTokens.title).textSelection(.enabled)
                                .onTapGesture(count: 2) { draftTitle = meeting.title; editingTitle = true }.help("Double-click to rename")
                        }
                        HStack(spacing: DesignTokens.space) {
                            Text(meeting.startedAt, format: .dateTime.month(.wide).day().year())
                            Text("/")
                            Text(meeting.startedAt, format: .dateTime.hour().minute())
                            Text("/")
                            Text(Transcript.timestamp(meeting.duration))
                        }.font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                        HStack(spacing: DesignTokens.space) {
                            Menu {
                                ForEach(state.templates) { template in
                                    Button(template.name) { state.changeTemplate(template.id, for: meeting.id) }
                                }
                                Divider()
                                Button("Edit templates…") { NSWorkspace.shared.open(Templates.directory) }
                            } label: {
                                HStack(spacing: DesignTokens.smallGap) {
                                    Text(state.templates.first(where: { $0.id == meeting.templateID })?.name ?? "Quick")
                                    Image(systemName: "chevron.down").font(DesignTokens.small)
                                }.font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(state.busy || state.capture.isRecording)
                            Spacer()
                            if let source = meeting.structuredNotes?.generatedBy {
                                Text(source.hasPrefix("Apple") ? "On this Mac" : source.components(separatedBy: ":").first ?? source)
                                    .font(DesignTokens.small).foregroundStyle(DesignTokens.faint)
                            }
                        }.padding(.top, DesignTokens.smallGap)
                    }
                    Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
                    if meeting.id == state.currentID && state.capture.isRecording { recordingBody }
                    else if meeting.state == .writing || meeting.state == .transcribing { processingBody }
                    else if meeting.state == .failed { failureBody }
                    else { MarkdownPage(markdown: state.markdown, omitTitle: true).id(meeting.id.uuidString + meeting.templateID + state.markdown) }
                    if !state.markdown.isEmpty || state.displayedTranscript != nil { transcriptBody }
                    if let notice = state.notice, meeting.state != .failed {
                        HStack(alignment: .top) {
                            Text(notice).font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
                            Spacer()
                            Button { state.notice = nil } label: { Image(systemName: "xmark").font(DesignTokens.small) }.buttonStyle(.plain)
                        }.padding(.top, DesignTokens.space)
                    }
                    Spacer(minLength: DesignTokens.margin)
                }.frame(maxWidth: DesignTokens.pageWidth, alignment: .leading)
                    .padding(.horizontal, DesignTokens.margin).padding(.top, DesignTokens.margin)
                    .frame(maxWidth: .infinity)
            }
        }.background(DesignTokens.paper)
    }
    private var recordingBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            HStack {
                Circle().fill(DesignTokens.ember).frame(width: DesignTokens.dot, height: DesignTokens.dot)
                Text("Listening.").font(DesignTokens.body)
                Spacer(); Text(Transcript.timestamp(state.elapsed)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
            }
            LiveLine(capture: state.capture)
            TextEditor(text: $state.liveNotes).font(DesignTokens.body).scrollContentBackground(.hidden)
                .frame(minHeight: DesignTokens.liveHeight * 2).overlay(alignment: .topLeading) {
                    if state.liveNotes.isEmpty { Text("A thought to keep, a question to ask…").font(DesignTokens.body).foregroundStyle(DesignTokens.faint).padding(DesignTokens.smallGap).allowsHitTesting(false) }
                }.accessibilityLabel("Your notes during the meeting")
            LiveTranscript(capture: state.capture)
            if let warning = state.capture.warning { Text(warning).font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft) }
            Text(state.preferences.providers.dataFlow).font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
            Button("Stop recording") { state.stop() }.buttonStyle(QuietButtonStyle(prominent: true, recording: true))
        }
    }
    private var processingBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            Text(meeting.state == .transcribing ? "Finishing the transcript…" : "Writing notes…").font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
            ProgressView().progressViewStyle(.linear).tint(DesignTokens.soft)
        }
    }
    private var failureBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            Text(meeting.failure ?? "Couldn't finish this meeting. Your files are saved.").font(DesignTokens.body).foregroundStyle(DesignTokens.soft).lineSpacing(DesignTokens.noteLineSpacing)
            HStack {
                Button(meeting.transcriptionFinal ? "Write notes again" : "Retry transcription") { state.retry(meeting.id) }
                    .buttonStyle(QuietButtonStyle()).disabled(state.busy)
                Button("Model settings") { state.showSettings?() }.buttonStyle(QuietButtonStyle())
            }
            if !state.markdown.isEmpty { MarkdownPage(markdown: state.markdown, omitTitle: true) }
        }
    }
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: DesignTokens.inset) {
            Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
            DisclosureGroup(isExpanded: $state.transcriptExpanded) {
                VStack(alignment: .leading, spacing: DesignTokens.inset) {
                    ForEach(Array((state.displayedTranscript?.turns() ?? []).enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: DesignTokens.space) {
                            HStack(spacing: DesignTokens.space) {
                                Text(turn.speaker.label).font(DesignTokens.chrome)
                                Text(Transcript.timestamp(turn.start)).font(DesignTokens.mono).foregroundStyle(DesignTokens.soft)
                            }
                            Text(turn.text).font(DesignTokens.body).foregroundStyle(DesignTokens.soft).lineSpacing(DesignTokens.noteLineSpacing).textSelection(.enabled)
                        }
                    }
                }.padding(.top, DesignTokens.inset)
            } label: { Text("Transcript").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft) }
            .tint(DesignTokens.soft)
        }.padding(.top, DesignTokens.inset)
    }
}

struct MarkdownPage: View {
    let markdown: String
    var omitTitle = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion") }
    @State private var appeared = false
    private var lines: [String] {
        markdown.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !(omitTitle && $0.hasPrefix("# ")) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                block(line).opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? .zero : DesignTokens.dryingOffset)
                    .animation(DesignTokens.fade.delay(Double(index) * DesignTokens.stagger), value: appeared)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).onAppear { appeared = true }
    }
    @ViewBuilder private func block(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3))).font(DesignTokens.section).padding(.top, DesignTokens.inset).padding(.bottom, DesignTokens.smallGap)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2))).font(DesignTokens.title).padding(.bottom, DesignTokens.gap)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4))).font(DesignTokens.section).padding(.top, DesignTokens.gap)
        } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: DesignTokens.gap) {
                Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft).padding(.top, DesignTokens.smallGap)
                rich(String(line.dropFirst(6)))
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.gap) {
                Text("–").foregroundStyle(DesignTokens.soft)
                rich(String(line.dropFirst(2)))
            }
        } else if line.hasPrefix("| ---") || line.hasPrefix("|---") {
            Rectangle().fill(DesignTokens.hairline).frame(height: DesignTokens.divider)
        } else if line.hasPrefix("|") {
            rich(line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "    "))
        } else { rich(line) }
    }
    private func rich(_ line: String) -> some View {
        Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
            .font(DesignTokens.body).lineSpacing(DesignTokens.noteLineSpacing).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
