import Foundation
import Testing
import HushKit
import MuesliCore

@Suite("On-device integration")
struct LocalModelTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_MODEL_TESTS"] == "1"))
    func realAppleModelProducesStructuredNotes() async throws {
        let provider = AppleNotesProvider()
        try await provider.preflight()
        let start = ContinuousClock.now
        let transcript = Transcript(locale: "en-US", segments: [
            .init(speaker: .me, start: 0, end: 10, text: "The welcome flow should have three steps, and each step should be skippable. I'll share revised designs tomorrow."),
            .init(speaker: .them, start: 11, end: 20, text: "Agreed. I'm Sam. I'll test the revised designs with three people. We need to decide whether the calendar step should be optional.")
        ])
        let result = try await MeetingSummarizer(generator: provider).summarize(transcript, context: .init(title: "Design review", start: .now))
        #expect(!result.notes.summary.isEmpty)
        #expect(!result.notes.actionItems.isEmpty)
        #expect(result.notes.generatedBy == "Apple on-device")
        print("On-device notes integration completed in \(start.duration(to: .now)).")
    }
}
