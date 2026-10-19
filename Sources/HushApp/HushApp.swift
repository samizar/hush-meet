import SwiftUI
import HushKit

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.openSettings() }.keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { delegate.state.updater?.checkForUpdates() }
                        .disabled(delegate.state.updater?.canCheck != true || delegate.state.preventsUpdateRestart)
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Recording") { delegate.state.start() }.keyboardShortcut("n")
                        .disabled(!delegate.state.canRecord)
                    Button("Stop Recording") { delegate.state.stop() }.keyboardShortcut(".")
                        .disabled(!delegate.state.capture.isRecording)
                    Divider()
                    Button("Open Notebook") { delegate.openMain() }.keyboardShortcut("0")
                }
                CommandGroup(after: .sidebar) {
                    Button("Home") { delegate.state.go(.home); delegate.openMain() }.keyboardShortcut("1", modifiers: [.command, .option])
                    Button("Action Items") { delegate.state.go(.tasks); delegate.openMain() }.keyboardShortcut("2", modifiers: [.command, .option])
                    Divider()
                    Button("Notes") { delegate.state.meetingTab = .notes }.keyboardShortcut("1")
                        .disabled(delegate.state.selected == nil)
                    Button("Transcript") { delegate.state.meetingTab = .transcript }.keyboardShortcut("2")
                        .disabled(delegate.state.selected == nil)
                    Button("Ask") { delegate.state.meetingTab = .ask }.keyboardShortcut("3")
                        .disabled(delegate.state.selected == nil)
                    Button(delegate.state.sideNotesVisible ? "Hide Side Notes" : "Show Side Notes") { delegate.state.toggleSideNotes() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
                CommandMenu("Meeting") {
                    let state = delegate.state
                    let selected = state.selected
                    Button("Edit Notes") { state.meetingTab = .notes; state.editingNotes = true }.keyboardShortcut("e")
                        .disabled(selected == nil || state.markdown.isEmpty || selected.map { state.isQueued($0.id) } == true)
                    Button("Write Notes Again") { if let id = selected?.id { state.regenerate(id) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(selected?.transcriptionFinal != true || selected.map { state.isQueued($0.id) } == true)
                    Divider()
                    Button("Copy Notes") {
                        if let meeting = selected { state.copy(Exporter.cleanMarkdown(state.markdown, meeting: meeting)); state.show(.success, "Notes copied") }
                    }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(selected == nil || state.markdown.isEmpty)
                    Button("Copy Transcript") {
                        if let meeting = selected { state.copy(Exporter.transcriptText(state.displayedTranscript, meeting: meeting)); state.show(.success, "Transcript copied") }
                    }.disabled(state.displayedTranscript?.segments.isEmpty != false)
                    Divider()
                    Button("Delete Meeting…") { if let id = selected?.id { state.delete(id) } }
                        .disabled(selected.map { !state.canDelete($0.id) } ?? true)
                }
            }
    }
}
