import Foundation
import Testing
import HushKit
import MuesliCore
@testable import HushApp

@Suite("Notebook 2.0") @MainActor
struct NotebookTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hush-app-" + UUID().uuidString) }

    @Test func parserUnderstandsTheTemplateSubset() {
        let markdown = """
        # Title to skip

        First line
        continues here.

        ## Decisions
        | Decision |
        | --- |
        | Ship it \\| now |

        - Point
          - Nested point
        1. Numbered
        - [ ] Send deck — Sam · 2026-10-21
        > A quote
        ---
        """
        let blocks = NoteParser.blocks(markdown, omitTitle: true)
        #expect(blocks.first == .paragraph("First line continues here."))
        #expect(blocks.contains(.heading(level: 2, text: "Decisions")))
        #expect(blocks.contains(.table(header: ["Decision"], rows: [["Ship it | now"]])))
        #expect(blocks.contains(.bullet(level: 1, text: "Nested point")))
        #expect(blocks.contains(.numbered(level: 0, marker: "1.", text: "Numbered")))
        #expect(blocks.contains { if case .task(_, 0, false, "Send deck — Sam · 2026-10-21") = $0 { true } else { false } })
        #expect(blocks.contains(.quote("A quote")))
        #expect(blocks.last == .rule)
        #expect(!blocks.contains(.heading(level: 1, text: "Title to skip")))
        let parts = NoteParser.taskParts("Send deck — Sam · 2026-10-21")
        #expect(parts.title == "Send deck" && parts.owner == "Sam" && parts.due == "2026-10-21")
    }

    @Test func rewrittenNotesKeepCheckedItems() {
        let old = "## Action items\n- [x] Send the deck — Sam\n- [ ] Book the room"
        let new = "## Next steps\n- [ ] Book the room\n- [ ] Send the deck — Sam\n- [ ] New item"
        #expect(AppState.carryingChecks(from: old, into: new) == "## Next steps\n- [ ] Book the room\n- [x] Send the deck — Sam\n- [ ] New item")
    }

    @Test func processingNeverBlocksRecording() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preview: false)
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Queued"); meeting.transcriptionFinal = true; meeting.state = .failed
        try await store.save(meeting, transcript: Transcript(locale: "en-US"))
        state.store = store; state.meetings = [meeting]
        state.retry(meeting.id)
        #expect(state.busy)
        #expect(state.canRecord) // A new recording can start while notes are being written.
        for _ in 0..<200 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!state.busy && state.meetings.first?.state == .failed)
    }

    @Test func cancellingAQueuedMeetingKeepsItsFiles() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preview: false)
        let store = try MeetingStore(root: root)
        var first = Meeting(title: "First"); first.transcriptionFinal = true
        var second = Meeting(title: "Second"); second.transcriptionFinal = true
        for meeting in [first, second] { try await store.save(meeting, transcript: Transcript(locale: "en-US")) }
        first.state = .failed; second.state = .failed
        state.store = store; state.meetings = [first, second]
        state.maintenance = true // Hold the queue so the second meeting stays waiting.
        state.retry(first.id); state.retry(second.id)
        #expect(state.queue == [first.id, second.id])
        state.cancelProcessing(second.id)
        #expect(state.queue == [first.id])
        for _ in 0..<100 where state.meeting(second.id)?.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.meeting(second.id)?.state == .failed)
        #expect(state.meeting(second.id)?.failure?.contains("cancelled") == true)
        #expect(try await store.transcript(second.id).locale == "en-US")
        state.maintenance = false; state.pump()
        for _ in 0..<200 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!state.busy)
    }

    @Test func renameAndSpeakerNamesPersist() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(preview: false)
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Before"); meeting.state = .ready
        try await store.save(meeting)
        state.store = store; state.meetings = [meeting]
        state.rename(meeting.id, title: "  After  ")
        state.renameSpeaker(meeting.id, speaker: .them, to: "Priya")
        #expect(await state.flushWrites())
        let saved = try #require(try await store.list().first)
        #expect(saved.title == "After" && saved.name(for: .them) == "Priya" && saved.name(for: .me) == "Me")
        state.renameSpeaker(meeting.id, speaker: .them, to: "Them")
        #expect(state.meeting(meeting.id)?.speakerNames == nil)
    }

    @Test func exportUsesTheMeetingTitleAndNames() {
        var meeting = Meeting(title: "Renamed by me", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        meeting.endedAt = meeting.startedAt.addingTimeInterval(1800); meeting.attendees = ["Sam"]; meeting.speakerNames = ["them": "Sam"]
        let clean = Exporter.cleanMarkdown("# Model title\n\nSummary.", meeting: meeting)
        #expect(clean.hasPrefix("# Renamed by me\n"))
        #expect(!clean.contains("Model title") && clean.contains("30 min") && clean.contains("With Sam") && clean.contains("Summary."))
        let transcript = Transcript(locale: "en-US", segments: [.init(speaker: .them, start: 3, end: 4, text: "Hello")])
        #expect(Exporter.transcriptText(transcript, meeting: meeting) == "[00:03] Sam: Hello")
    }

    @Test func progressDescribesLongMeetings() throws {
        #expect(ProcessingProgress(phase: .writing(part: 1, of: 1)).title == "Writing notes…")
        #expect(ProcessingProgress(phase: .writing(part: 3, of: 8)).title == "Reading part 3 of 8…")
        #expect(ProcessingProgress(phase: .writing(part: 9, of: 8)).title == "Bringing it together…")
        let fraction = try #require(ProcessingProgress(phase: .writing(part: 3, of: 8)).fraction)
        #expect(fraction > 0.5 && fraction < 1)
    }

    @Test func demoNeverTouchesStorage() {
        let state = AppState(preview: true)
        #expect(state.store == nil && !state.meetings.isEmpty && !state.tasks.isEmpty)
        #expect(state.calendar.meetings.count == 3)
        #expect(state.canRecord)
    }
}
