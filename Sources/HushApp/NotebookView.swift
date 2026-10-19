import SwiftUI
import HushKit
import MuesliCore

struct NotebookView: View {
    @Bindable var state: AppState
    @State private var selection: Set<Route> = [.home]
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(state: state, selection: $selection)
                .searchable(text: $state.search, placement: .sidebar, prompt: "Search")
                .navigationSplitViewColumnWidth(min: 220, ideal: DesignTokens.sidebarWidth, max: 340)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: DesignTokens.detailMinWidth, ideal: 760)
                .overlay(alignment: .top) {
                    BannerStack(state: state).frame(maxWidth: 520).padding(.top, DesignTokens.gap).padding(.horizontal, DesignTokens.inset)
                }
        }
        .inspector(isPresented: Binding(get: { state.inspectorShown && state.selected != nil && selection.count == 1 && !isLive },
                                        set: { if !isLive { state.inspectorShown = $0 } })) {
            if let meeting = state.selected {
                InspectorView(state: state, meeting: meeting).inspectorColumnWidth(min: 240, ideal: DesignTokens.inspectorWidth, max: 400)
            }
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .background(DesignTokens.paper)
        .onChange(of: state.search) { state.searchChanged() }
        .onChange(of: selection) { _, new in
            guard new.count == 1, let route = new.first, route != state.route else { return }
            state.editingNotes = false
            state.go(route)
        }
        .onChange(of: state.route) { _, route in if !selection.contains(route) || selection.count > 1 { selection = [route] } }
        .onAppear { selection = [state.route] }
    }

    /// The live page has its own notes editor, so side notes step aside while recording.
    private var isLive: Bool { state.capture.isRecording && state.selectedID != nil && state.selectedID == state.currentID }

    @ViewBuilder private var detail: some View {
        if selection.count > 1 {
            multiSelection
        } else {
            switch state.route {
            case .home: HomeView(state: state)
            case .tasks: ActionItemsView(state: state)
            case .meeting:
                if let meeting = state.selected {
                    MeetingDetailView(state: state, meeting: meeting, tab: $state.meetingTab, editing: $state.editingNotes)
                } else { HomeView(state: state) }
            }
        }
    }

    private var multiSelection: some View {
        let ids = selection.compactMap { if case .meeting(let id) = $0 { id } else { nil } }
        return VStack(spacing: DesignTokens.gap) {
            Image(systemName: "square.stack").font(.system(size: 28)).foregroundStyle(DesignTokens.faint)
            Text("\(ids.count) meetings selected").font(DesignTokens.heading)
            Button("Delete \(ids.count) meetings…", role: .destructive) { state.delete(ids) }
                .buttonStyle(.hushSecondary).disabled(!ids.contains(where: state.canDelete))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(DesignTokens.paper)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            if let meeting = state.selected, selection.count == 1 {
                ShareMenu(state: state, meeting: meeting)
            }
            if state.capture.isRecording {
                Button { state.stop() } label: {
                    Label { Text("Stop · " + Transcript.timestamp(state.elapsed)) } icon: { Image(systemName: "stop.fill") }
                        .labelStyle(.titleAndIcon)
                }
                .tint(DesignTokens.ember).help("Stop recording (⌘.)")
            } else {
                Button { state.start() } label: {
                    Label { Text("Record") } icon: { Image(systemName: "record.circle.fill").foregroundStyle(DesignTokens.ember) }
                        .labelStyle(.titleAndIcon)
                }
                .help("Start recording (⌘N)").disabled(!state.canRecord)
            }
        }
        if state.selected != nil && selection.count == 1 && !isLive {
            ToolbarItem {
                Button { state.toggleInspector() } label: { Label("Side notes", systemImage: "sidebar.right") }
                    .help(state.inspectorShown ? "Hide side notes (⌥⌘I)" : "Show side notes (⌥⌘I)")
            }
        }
    }
}

/// Copy, save and share for one meeting.
struct ShareMenu: View {
    @Bindable var state: AppState
    let meeting: Meeting
    var body: some View {
        Menu {
            Section("Notes") {
                Button("Copy notes") { state.copy(Exporter.cleanMarkdown(state.markdown, meeting: meeting)); state.show(.success, "Notes copied") }
                Button("Copy formatted notes") { Exporter.copyRich(state.markdown, meeting: meeting); state.show(.success, "Formatted notes copied", detail: "Paste into Mail, Notes, Docs or Slack.") }
                Button("Save as Markdown…") { Exporter.markdown(Exporter.cleanMarkdown(state.markdown, meeting: meeting), title: meeting.title) }
                Button("Save as PDF…") { Exporter.pdf(Exporter.cleanMarkdown(state.markdown, meeting: meeting), meeting: meeting) }
                Button("Email notes…") { Exporter.email(state.markdown, meeting: meeting) }
            }.disabled(state.markdown.isEmpty)
            Section("Transcript") {
                Button("Copy transcript") { state.copy(Exporter.transcriptText(state.displayedTranscript, meeting: meeting)); state.show(.success, "Transcript copied") }
                Button("Save transcript…") { Exporter.saveTranscript(state.displayedTranscript, meeting: meeting) }
            }.disabled(state.displayedTranscript?.segments.isEmpty != false)
            Divider()
            Button("Show in Finder") { state.revealFolder(meeting.id) }.disabled(state.isDemo)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Copy, save or share")
    }
}
