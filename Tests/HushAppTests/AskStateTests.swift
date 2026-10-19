import Foundation
import Testing
import os
import HushKit
import MuesliCore
@testable import HushApp

private final class StubAnswerer: AnswerGenerator, @unchecked Sendable {
    let budget: Int
    let prompts = OSAllocatedUnfairLock(initialState: [String]())
    init(budget: Int) { self.budget = budget }
    var displayName: String { "Apple on-device" }
    var transcriptCharacterBudget: Int { get async { budget } }
    func preflight() async throws {}
    func answer(system: String, user: String) async throws -> String {
        prompts.withLock { $0.append(user) }
        return "  We ship Friday [00:30].\n"
    }
}

@Suite("Ask in the notebook") @MainActor
struct AskStateTests {
    private func settle(_ state: AppState, _ id: UUID) async throws {
        for _ in 0..<400 where state.isAsking(id) { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func previewAnswersWithoutAModelOrStorage() async throws {
        let state = AppState(preview: true)
        let stub = StubAnswerer(budget: 3_600)
        state.answerers = { _ in stub }
        let savedPreferences = UserDefaults.standard.data(forKey: "hush.preferences")
        let meeting = try #require(state.meetings.first)
        state.select(meeting.id)
        state.ask("What did we decide?", in: meeting.id)
        #expect(state.isAsking(meeting.id))
        try await settle(state, meeting.id)
        let exchange = try #require(state.exchanges(for: meeting.id).first)
        #expect(exchange.answer?.contains("[01:16]") == true && exchange.source == "Preview")
        #expect(stub.prompts.withLock { $0.isEmpty }) // No model call in preview mode.
        state.addAnswerToSideNotes(exchange.id, in: meeting.id)
        #expect(state.meeting(meeting.id)?.userNotes == "Q: What did we decide?\nA: " + (exchange.answer ?? ""))
        #expect(state.store == nil && state.savingIDs.isEmpty)
        #expect(UserDefaults.standard.data(forKey: "hush.preferences") == savedPreferences)
    }

    @Test func onDeviceQuestionReadsNotesAndTheMatchingPartOfALongTranscript() async throws {
        let state = AppState(preview: false)
        try #require(state.preferences.providers.notes.isOnDevice) // A cloud default would ask first.
        let stub = StubAnswerer(budget: 1_000)
        state.answerers = { _ in stub }
        var meeting = Meeting(title: "Planning"); meeting.state = .ready; meeting.transcriptionFinal = true
        meeting.userNotes = "Private aside"; meeting.useSideNotesAsContext = false
        state.meetings = [meeting]; state.route = .meeting(meeting.id)
        state.markdown = "## Summary\nWe planned the launch."
        let segments: [TranscriptSegment] = (0..<120).map { (index: Int) -> TranscriptSegment in
            let text = index == 90 ? "The launch is on Friday." : "Unrelated chatter \(index) about lunch options nearby."
            let start = Double(index * 10)
            return TranscriptSegment(speaker: index % 2 == 0 ? .me : .them, start: start, end: start + 5, text: text)
        }
        state.displayedTranscript = Transcript(locale: "en-US", segments: segments)
        state.ask("When is the launch?", in: meeting.id)
        try await settle(state, meeting.id)
        let exchange = try #require(state.exchanges(for: meeting.id).first)
        #expect(exchange.answer == "We ship Friday [00:30]." && exchange.partial && exchange.onDevice && exchange.error == nil)
        let prompt = try #require(stub.prompts.withLock { $0.first })
        #expect(prompt.contains("We planned the launch.") && prompt.contains("The launch is on Friday."))
        #expect(!prompt.contains("Private aside")) // Side notes kept "for you only" never go to a model.
        #expect(state.meeting(meeting.id)?.userNotes == "Private aside")

        // A follow-up carries the earlier exchange, briefly.
        state.ask("Who said that?", in: meeting.id)
        try await settle(state, meeting.id)
        #expect(stub.prompts.withLock { $0.last }?.contains("<earlier_exchange>\nQuestion: When is the launch?") == true)
        state.clearConversation(meeting.id)
        #expect(state.exchanges(for: meeting.id).isEmpty)
    }

    @Test func citedTimestampsOpenTheTranscript() throws {
        let text = AskExchangeView.attributed("Ship **Friday** [00:30], not [59:00].", duration: 120)
        #expect(String(text.characters) == "Ship Friday [00:30], not [59:00].")
        #expect(text.runs.compactMap(\.link) == [URL(string: "hush-time://30")!])
        let state = AppState(preview: true)
        let meeting = try #require(state.meetings.first)
        state.select(meeting.id); state.meetingTab = .ask
        state.showTranscript(at: 30)
        #expect(state.transcriptFocus == 1 && state.meetingTab == .transcript)
    }
}
