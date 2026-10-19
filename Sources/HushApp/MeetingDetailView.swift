import SwiftUI
import HushKit
import MuesliCore

enum MeetingTab: String, CaseIterable, Identifiable {
    case notes, transcript, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: "Notes"
        case .transcript: "Transcript"
        case .ask: "Ask"
        }
    }
}

/// One meeting as a page.
struct MeetingDetailView: View {
    @Bindable var state: AppState
    let meeting: Meeting
    @Binding var tab: MeetingTab
    @Binding var editing: Bool
    @State private var draftTitle = ""
    @State private var draftNotes = ""
    @FocusState private var titleFocused: Bool
    @State private var renaming = false

    private var isLive: Bool { state.currentID == meeting.id && (state.capture.isRecording || state.isStopping) }
    private var template: NoteTemplate? { state.template(for: meeting) }

    private var showsAsk: Bool { tab == .ask && !(isLive && state.capture.isRecording) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.block) {
                    header
                    if isLive && state.capture.isRecording {
                        LiveMeetingView(state: state, meeting: meeting)
                    } else {
                        controls
                        content
                    }
                }
                .frame(maxWidth: isLive ? 1100 : DesignTokens.pageWidth, alignment: .leading)
                .padding(.horizontal, DesignTokens.block + 8).padding(.top, DesignTokens.margin - 8).padding(.bottom, showsAsk ? DesignTokens.block : 80)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsAsk { AskComposer(state: state, meeting: meeting) }
            }
            .onChange(of: state.exchanges(for: meeting.id).count) { _, count in
                guard count > 0 else { return }
                withAnimation(DesignTokens.fade) { proxy.scrollTo(AskView.endID, anchor: .bottom) }
            }
            .onChange(of: state.exchanges(for: meeting.id).last?.isPending) { _, pending in
                // A finished answer reads from its question down.
                guard pending == false, let last = state.exchanges(for: meeting.id).last else { return }
                withAnimation(DesignTokens.fade) { proxy.scrollTo(last.id, anchor: .top) }
            }
            .onChange(of: state.transcriptFocus) { _, focus in
                guard let focus else { return }
                Task { try? await Task.sleep(for: .milliseconds(120)); withAnimation(DesignTokens.fade) { proxy.scrollTo(TranscriptView.anchor(focus), anchor: .center) } }
            }
        }
        .background(DesignTokens.paper)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(showsAsk ? .soft : .automatic, for: .bottom)
        .onAppear { draftTitle = meeting.title }
        .onChange(of: meeting.id) { draftTitle = meeting.title; editing = false; renaming = false }
        .onChange(of: meeting.title) { if !renaming { draftTitle = meeting.title } }
        .onChange(of: titleFocused) { if !titleFocused && renaming { commitTitle(); renaming = false } }
        .onChange(of: editing) { if editing { draftNotes = state.markdown } }
        .onChange(of: tab) { if tab != .transcript { state.transcriptFocus = nil } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.gap) {
            if renaming {
                TextField("Meeting title", text: $draftTitle, axis: .vertical)
                    .font(DesignTokens.title).textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit { commitTitle(); renaming = false }
                    .onExitCommand { draftTitle = meeting.title; renaming = false }
                    .onAppear { titleFocused = true }
                    .accessibilityLabel("Meeting title")
            } else {
                Text(meeting.title).font(DesignTokens.title).fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { draftTitle = meeting.title; renaming = true }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton).accessibilityHint("Rename this meeting")
            }
            FlowChips(meeting: meeting, state: state)
        }
    }
    private func commitTitle() {
        let clean = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { draftTitle = meeting.title } else if clean != meeting.title { state.rename(meeting.id, title: clean) }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: DesignTokens.space) {
            Picker("View", selection: $tab) {
                ForEach(MeetingTab.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if tab == .notes && !editing {
                Menu {
                    ForEach(state.templates) { item in
                        Button { state.changeTemplate(item.id, for: meeting.id) } label: {
                            if item.id == meeting.templateID { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                        }
                    }
                    Divider()
                    Button("Edit templates…") { state.showSettings?(.templates) }
                } label: {
                    Label(template?.name ?? "Template", systemImage: "doc.text").font(DesignTokens.chrome)
                }
                .menuStyle(.button).buttonStyle(.hushSecondary).frame(maxWidth: 180)
                .disabled(state.isQueued(meeting.id) || isLive)
                .help("Choose how these notes are written")
                if meeting.transcriptionFinal {
                    IconButton(symbol: "arrow.clockwise", help: "Write notes again") { state.regenerate(meeting.id) }
                        .disabled(state.isQueued(meeting.id))
                }
                IconButton(symbol: "pencil", help: "Edit notes (⌘E)") { editing = true }
                    .disabled(state.markdown.isEmpty || state.isQueued(meeting.id))
            }
            if tab == .ask && !state.exchanges(for: meeting.id).isEmpty {
                Button("Clear") { state.clearConversation(meeting.id) }.buttonStyle(.hushQuiet)
                    .help("Remove these questions and answers. Anything you added to side notes stays.")
            }
            if tab == .notes && editing {
                Button("Cancel") { editing = false }.buttonStyle(.hushQuiet).keyboardShortcut(.cancelAction)
                Button("Save") { state.saveEditedNotes(meeting.id, markdown: draftNotes); editing = false }
                    .buttonStyle(.hushPrimary).keyboardShortcut("s", modifiers: .command)
            }
        }
        .frame(minHeight: DesignTokens.buttonHeight)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if tab == .transcript {
            TranscriptView(state: state, meeting: meeting, transcript: state.displayedTranscript)
        } else if tab == .ask {
            AskView(state: state, meeting: meeting)
        } else if editing {
            NotesEditor(text: $draftNotes)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.block) {
                if let progress = state.progress[meeting.id] ?? (meeting.isProcessing ? ProcessingProgress(phase: .waiting) : nil), state.isQueued(meeting.id) || meeting.isProcessing {
                    ProcessingCard(state: state, meeting: meeting, progress: progress)
                } else if meeting.state == .failed {
                    FailureCard(state: state, meeting: meeting) { tab = .transcript }
                }
                if meeting.sideNotesChanged && !state.isQueued(meeting.id) && meeting.transcriptionFinal {
                    StaleNotesCallout { state.regenerate(meeting.id) }
                }
                if !state.markdown.isEmpty {
                    MarkdownView(markdown: state.markdown, animate: true) { line, text in
                        state.toggleTask(NoteTask(meetingID: meeting.id, line: line, text: text, done: false))
                    }
                    .id(meeting.id.uuidString + (meeting.structuredNotes?.summary ?? "") + meeting.templateID)
                    if let source = meeting.structuredNotes?.generatedBy { provenance(source) }
                } else if meeting.state == .ready {
                    Text("These notes are empty. Write them again from the transcript, or edit them yourself.")
                        .font(DesignTokens.body).foregroundStyle(DesignTokens.soft)
                }
            }
        }
    }

    private func provenance(_ source: String) -> some View {
        let local = source.hasPrefix("Apple") || source.lowercased().contains("ollama") || source.lowercased().contains("lm studio")
        let name = source.components(separatedBy: ":").first ?? source
        return HStack(spacing: 6) {
            Image(systemName: local ? "lock" : "arrow.up.forward.circle").font(.system(size: 10))
            Text(local ? "Written on this Mac by \(name)" : "Written by \(name)" + (source.contains(":") ? " · " + (source.components(separatedBy: ":").last ?? "") : ""))
            if meeting.notesEdited == true { Text("· Edited") }
        }
        .font(DesignTokens.small).foregroundStyle(DesignTokens.faint).padding(.top, DesignTokens.space)
    }
}

/// Date, duration, people and privacy for a meeting.
struct FlowChips: View {
    let meeting: Meeting
    let state: AppState
    var body: some View {
        HStack(spacing: 6) {
            Chip(meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()), symbol: "calendar")
            if meeting.endedAt != nil { Chip(meeting.duration.spoken, symbol: "clock") }
            if let attendees = meeting.attendees, !attendees.isEmpty {
                Chip(attendees.prefix(2).joined(separator: ", ") + (attendees.count > 2 ? " +\(attendees.count - 2)" : ""), symbol: "person.2")
                    .help(attendees.joined(separator: ", "))
            }
            if let url = meeting.joinURL {
                Button { NSWorkspace.shared.open(url) } label: { Chip(url.host() ?? "Call link", symbol: "video") }.buttonStyle(.plain).help("Open the call link")
            }
            if Locale(identifier: meeting.locale).language.languageCode != Locale.current.language.languageCode {
                Chip(Locale.current.localizedString(forIdentifier: meeting.locale) ?? meeting.locale, symbol: "globe")
            }
        }
    }
}

struct ProcessingCard: View {
    @Bindable var state: AppState
    let meeting: Meeting
    let progress: ProcessingProgress
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.gap) {
                HStack(spacing: DesignTokens.gap) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.activeJob == meeting.id ? progress.title : "Waiting for another meeting to finish…").font(DesignTokens.chromeStrong)
                        Text(state.preferences.providers.notes.isOnDevice ? "On this Mac. You can keep working, or start another recording." : "Using \(state.preferences.providers.privacyLabel.replacingOccurrences(of: "Uses ", with: "")).")
                            .font(DesignTokens.small).foregroundStyle(DesignTokens.soft)
                    }
                    Spacer()
                    Button("Cancel") { state.cancelProcessing(meeting.id) }.buttonStyle(.hushQuiet).controlSize(.small)
                }
                ProgressLine(fraction: state.activeJob == meeting.id ? progress.fraction : nil)
            }
        }
    }
}

struct FailureCard: View {
    @Bindable var state: AppState
    let meeting: Meeting
    var showTranscript: () -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.gap) {
                HStack(alignment: .top, spacing: DesignTokens.gap) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(DesignTokens.amber).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.transcriptionFinal ? "Notes weren't written" : "The transcript isn't finished").font(DesignTokens.chromeStrong)
                        Text(meeting.failure ?? "Something went wrong. Your files are saved.").font(DesignTokens.chrome).foregroundStyle(DesignTokens.soft)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                HStack(spacing: DesignTokens.space) {
                    Button(meeting.transcriptionFinal ? "Write notes again" : "Try again") { state.retry(meeting.id) }
                        .buttonStyle(.hushPrimary).disabled(state.isQueued(meeting.id))
                    Button("AI model settings") { state.showSettings?(.models) }.buttonStyle(.hushSecondary)
                    if state.displayedTranscript?.segments.isEmpty == false {
                        Button("Read transcript", action: showTranscript).buttonStyle(.hushQuiet)
                    }
                }
            }
        }
    }
}

struct StaleNotesCallout: View {
    let update: () -> Void
    var body: some View {
        HStack(spacing: DesignTokens.gap) {
            Image(systemName: "note.text.badge.plus").foregroundStyle(DesignTokens.soft)
            Text("Your side notes changed since these notes were written.").font(DesignTokens.chrome)
            Spacer()
            Button("Update notes", action: update).buttonStyle(.hushSecondary).controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.gap).padding(.vertical, 10)
        .background(DesignTokens.selected, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
    }
}

/// Plain Markdown editing with a short legend.
struct NotesEditor: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space) {
            TextEditor(text: $text)
                .font(.system(size: 14).monospaced()).lineSpacing(5)
                .scrollContentBackground(.hidden).focused($focused)
                .padding(DesignTokens.gap).frame(minHeight: 420)
                .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.cardRadius).strokeBorder(DesignTokens.ink.opacity(0.18)))
            Text("Markdown: ## heading · - bullet · - [ ] action item · **bold**. ⌘S saves, Esc cancels.")
                .font(DesignTokens.small).foregroundStyle(DesignTokens.faint)
        }
        .onAppear { focused = true }
    }
}
