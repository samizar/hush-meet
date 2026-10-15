import Foundation
import HushKit
import MuesliCore

extension AppState {
    func seedDemo() {
        preferences.onboardingCompleted = true
        preferences.calendarEnabled = false
        templates = Templates.builtIns.map { id, contents in NoteTemplate(url: URL(fileURLWithPath: "/preview/" + id + ".md"), contents: contents) }
        let day = Calendar.current.startOfDay(for: .now)
        let samples: [(String, TimeInterval, Int, String)] = [
            ("A quieter first impression", 10 * 3600, 32, "standard"),
            ("Monday, with a little more clarity", 9 * 3600, 18, "quick"),
            ("Making room for the next chapter", -86400 + 15 * 3600, 46, "one-on-one"),
            ("The small details that matter", -86400 + 11 * 3600, 24, "standard"),
            ("A conversation with Northstar", -172800 + 14 * 3600, 41, "sales")
        ]
        meetings = samples.map { title, offset, duration, template in
            var meeting = Meeting(title: title, startedAt: day.addingTimeInterval(offset), locale: "en-US", templateID: template)
            meeting.endedAt = meeting.startedAt.addingTimeInterval(Double(duration) * 60)
            meeting.state = .ready; meeting.transcriptionFinal = true
            let notes = GeneratedNotes(title: title,
                summary: "We walked through the new welcome experience and agreed it should feel like opening a notebook: a little space, a clear next step, and nothing asking for attention. The first version will focus on getting someone into their first conversation.",
                keyPoints: ["Give the first screen one job: help someone start their first meeting.",
                            "Keep permissions in context. Explain what each one makes possible, and let people come back to it.",
                            "The writing should feel like a thoughtful colleague — short, warm, and specific."],
                decisions: ["Keep the three-step welcome flow. Each step can be skipped.", "Use the quiet notebook direction across the whole experience."],
                actionItems: [.init(title: "Share the revised welcome screens", owner: "Me", dueText: "Friday"),
                              .init(title: "Try the first-run experience with three new people", owner: "Sam"),
                              .init(title: "Bring the permission copy into the next design review", owner: "Alex")],
                openQuestions: ["How much context does someone need before the first recording?"])
            meeting.structuredNotes = MeetingNotes(normalizing: notes, context: .init(title: title, start: meeting.startedAt), generatedBy: "Apple on-device")
            return meeting
        }
        if let first = meetings.first { selectedID = first.id; loadDemo(first.id) }
    }
    func loadDemo(_ id: UUID) {
        guard let meeting = meetings.first(where: { $0.id == id }), let notes = meeting.structuredNotes,
              let template = templates.first(where: { $0.id == meeting.templateID }) else { return }
        markdown = template.render(notes)
        displayedTranscript = Transcript(startedAt: meeting.startedAt, locale: "en-US", segments: [
            .init(speaker: .me, start: 12, end: 29, text: "I keep coming back to the idea of opening a notebook. A little space, a clear next step. What if the first screen only helps you get into your first meeting?"),
            .init(speaker: .them, start: 30, end: 52, text: "That feels right. Let's keep the three-step welcome flow, but make every step skippable. I'll try it with three new people before the next review."),
            .init(speaker: .me, start: 58, end: 73, text: "I'll share the revised screens on Friday. Alex, could you bring the permission copy to the design review?")
        ])
    }
}
