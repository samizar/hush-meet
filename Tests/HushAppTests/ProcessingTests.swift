import Foundation
import Testing
import HushKit
import MuesliCore
@testable import HushApp

@Suite("Processing recovery") @MainActor
struct ProcessingTests {
    @Test func rapidSideNotesEditsSaveLatestTextAcrossSelections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preview: false)
        let store = try MeetingStore(root: root)
        var first = Meeting(title: "First"); first.state = .ready
        var second = Meeting(title: "Second"); second.state = .ready
        try await store.save(first); try await store.save(second)
        state.store = store; state.meetings = [first, second]; state.selectedID = first.id
        for i in 0..<20 { state.setSideNotes(first.id, text: "Agenda version \(i)") }
        state.selectedID = second.id
        state.setSideNotes(second.id, text: "Separate context", includeInContext: false)
        #expect(await state.flushSideNotes())
        let saved = try await store.list()
        #expect(saved.first { $0.id == first.id }?.userNotes == "Agenda version 19")
        #expect(saved.first { $0.id == second.id }?.userNotes == "Separate context")
        #expect(saved.first { $0.id == second.id }?.includesSideNotes == false)
        #expect(state.sideNotesSaving.isEmpty && state.sideNotesSaveErrors.isEmpty)
    }
    @Test func failedRetryRestoresControlsAndAllowsUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState()
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Empty synthetic test")
        meeting.transcriptionFinal = true; meeting.state = .failed
        try await store.save(meeting, transcript: Transcript(locale: "en-US"))
        state.store = store; state.meetings = [meeting]
        state.retry(meeting.id)
        #expect(state.busy)
        for _ in 0..<100 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!state.busy); #expect(!state.preventsUpdateRestart)
        #expect(state.canRecord); #expect(!state.canCancelProcessing)
        #expect(state.meetings.first?.state == .failed)
        #expect(state.meetings.first?.failure?.contains("No speech") == true)
    }
    @Test func missingMeetingAlwaysReleasesBusyState() async throws {
        let state = AppState()
        state.retry(UUID())
        for _ in 0..<100 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!state.busy); #expect(!state.preventsUpdateRestart)
    }
}
