import Foundation
import Testing
import HushKit
import MuesliCore
@testable import HushApp

@Suite("Processing recovery") @MainActor
struct ProcessingTests {
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
