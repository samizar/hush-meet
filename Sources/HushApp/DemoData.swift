import Foundation
import HushKit
import MuesliCore

/// Synthetic meetings for `--demo`. Nothing here is saved, and no real calendar or file is read.
extension AppState {
    func seedDemo() {
        // Preview never reads or changes real preferences.
        preferences = Preferences()
        preferences.onboardingCompleted = true; preferences.recordingConsent = true
        preferences.calendarEnabled = true
        templates = Templates.builtIns.map { id, contents in NoteTemplate(url: URL(fileURLWithPath: "/preview/" + id + ".md"), contents: contents) }
        let day = Calendar.current.startOfDay(for: .now)
        let samples: [(String, TimeInterval, Int, String, [String], GeneratedNotes)] = [
            ("Onboarding redesign review", 10 * 3600, 32, "standard", ["Sam Lee", "Alex Kim"], GeneratedNotes(
                summary: "We reviewed the new welcome flow and agreed it should feel like opening a notebook: a little space, one clear next step, nothing asking for attention. The first version focuses on getting someone into their first conversation within a minute.",
                keyPoints: ["The first screen has one job: help someone start their first meeting.",
                            "Permissions are explained in context, and every step can be skipped and revisited.",
                            "Copy should read like a thoughtful colleague — short, warm and specific."],
                decisions: ["Keep the five-step welcome flow, each step skippable.", "Ship the quiet notebook direction across every surface."],
                actionItems: [.init(title: "Share the revised welcome screens", owner: "Me", dueDate: Self.isoDay(2)),
                              .init(title: "Test the first-run flow with three new people", owner: "Sam", dueText: "before the review"),
                              .init(title: "Bring the permission copy to the design review", owner: "Alex")],
                openQuestions: ["How much context does someone need before their first recording?"])),
            ("Weekly sync with platform", 9 * 3600, 18, "quick", ["Priya Natarajan"], GeneratedNotes(
                summary: "Priya confirmed the storage migration is on track for Thursday. Search indexing now rebuilds in under a second for a thousand meetings. We'll pause the export work until after the release.",
                actionItems: [.init(title: "Send the migration checklist to Priya", owner: "Me", dueDate: Self.isoDay(1)),
                              .init(title: "Confirm the release window with support", owner: "Priya")])),
            ("Customer call — Northstar", -86400 + 15 * 3600, 46, "sales", ["Jordan Ellis", "Mia Chen"], GeneratedNotes(
                summary: "Northstar wants meeting notes that never leave their laptops; legal blocks any tool that uploads audio. They run 40 customer calls a week and want action items to land in Reminders. Budget is approved for this quarter.",
                keyPoints: ["Hard requirement: on-device processing, no audio upload.", "About 40 customer calls a week across two teams.",
                            "They would pilot with eight people first."],
                decisions: ["Start a two-week pilot with the success team."],
                actionItems: [.init(title: "Send the security overview", owner: "Me", dueDate: Self.isoDay(1)),
                              .init(title: "Schedule the pilot kickoff", owner: "Jordan", dueText: "next week")],
                openQuestions: ["Who signs off on the pilot from their IT side?"])),
            ("1:1 with Alex", -86400 + 11 * 3600, 24, "one-on-one", ["Alex Kim"], GeneratedNotes(
                summary: "Alex is enjoying the design-system work and wants more time with research. We agreed to protect Friday mornings for focused work.",
                keyPoints: ["Energy is good; the review cadence is helping.", "Wants to sit in on two customer interviews this month."],
                decisions: ["Friday mornings stay meeting-free for Alex."],
                actionItems: [.init(title: "Invite Alex to the Northstar interviews", owner: "Me")])),
            ("Hiring loop debrief", -4 * 86400 + 14 * 3600, 41, "interview", ["Dana Ortiz", "Lee Park"], GeneratedNotes(
                summary: "The panel discussed the product designer candidate's portfolio walkthrough and systems exercise. Feedback was specific and evidence-based across all four interviews.",
                keyPoints: ["Portfolio showed clear reasoning from research to shipped work.", "Systems exercise: strong on constraints, lighter on edge cases."],
                decisions: [], actionItems: [.init(title: "Collect written feedback from every interviewer", owner: "Dana", dueText: "Friday")]))
        ]
        meetings = samples.map { title, offset, duration, template, attendees, notes in
            var meeting = Meeting(title: title, startedAt: day.addingTimeInterval(offset), locale: "en-US", templateID: template)
            meeting.endedAt = meeting.startedAt.addingTimeInterval(Double(duration) * 60)
            meeting.state = .ready; meeting.transcriptionFinal = true; meeting.attendees = attendees
            var generated = notes; generated.title = title
            meeting.structuredNotes = MeetingNotes(normalizing: generated, context: meeting.summaryContext, generatedBy: "Apple on-device")
            if title.hasPrefix("1:1") { meeting.userNotes = "Ask about research time\nCheck in on workload after launch"; meeting.speakerNames = ["them": "Alex"] }
            return meeting
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-failure"), meetings.count > 1 {
            meetings[1].state = .failed; meetings[1].failure = "Apple's notes model is still getting ready. Try again after it finishes downloading."
        }
        demoMarkdown = Dictionary(uniqueKeysWithValues: meetings.compactMap { meeting in
            guard let notes = meeting.structuredNotes, let template = templates.first(where: { $0.id == meeting.templateID }) else { return nil }
            var text = template.render(notes)
            if meeting.title.hasPrefix("Weekly"), let toggled = NotesMarkdown.toggling(text, line: NotesMarkdown.tasks(in: text, meetingID: meeting.id).last?.line ?? -1) { text = toggled }
            return (meeting.id, text)
        })
        tasks = demoTasks()
        let now = Date.now
        calendar.preview([
            CalendarMeeting(id: "demo-1", title: "Design critique", start: now.addingTimeInterval(14 * 60), end: now.addingTimeInterval(59 * 60),
                            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: ["Sam Lee", "Alex Kim", "Mia Chen"]),
            CalendarMeeting(id: "demo-2", title: "Northstar pilot kickoff", start: now.addingTimeInterval(3 * 3600), end: now.addingTimeInterval(4 * 3600),
                            joinURL: URL(string: "https://zoom.us/j/123456789"), attendees: ["Jordan Ellis"]),
            CalendarMeeting(id: "demo-3", title: "Planning", start: day.addingTimeInterval(86400 + 10 * 3600), end: day.addingTimeInterval(86400 + 11 * 3600), attendees: ["Priya Natarajan", "Dana Ortiz"])
        ])
        let start = ProcessInfo.processInfo.arguments.contains("--demo-meeting") ? meetings.first.map { Route.meeting($0.id) } : nil
        route = start ?? .home
        if case .meeting(let id) = route { loadDemo(id) }
    }

    // MARK: Simulated recording

    func startDemoRecording(_ event: CalendarMeeting?) {
        var meeting = Meeting(title: event?.title ?? Self.defaultTitle(), locale: "en-US")
        meeting.attendees = event?.attendees; meeting.joinURL = event?.joinURL; meeting.calendarEventID = event?.id
        meetings.insert(meeting, at: 0); currentID = meeting.id
        route = .meeting(meeting.id); markdown = ""; displayedTranscript = nil; liveNotes = ""; elapsed = 0
        dismissCard?()
        capture.startPreview(lines: [
            (.me, "Thanks for joining. Let's look at where the pilot stands and agree on next steps."),
            (.them, "Sure. The team has used it for a week and nobody has asked to switch back."),
            (.me, "Great. Any blockers before we roll it out to the second team?"),
            (.them, "Only the export to Reminders. Can that be ready by Friday?"),
            (.me, "Yes, I'll have it done by Friday and send a short note when it ships."),
            (.them, "Perfect. I'll schedule the rollout review for next Tuesday.")
        ])
        recordingChanged?(true)
        Task {
            while capture.isRecording, currentID == meeting.id {
                elapsed = Date.now.timeIntervalSince(capture.startedAt ?? .now)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopDemoRecording(_ id: UUID) {
        let transcript = capture.stopPreview()
        recordingChanged?(false)
        update(id) { $0.endedAt = .now; $0.userNotes = liveNotes; $0.state = .writing; $0.transcriptionFinal = true }
        currentID = nil; activeEvent = nil
        displayedTranscript = transcript
        activeJob = id
        Task {
            for part in 1...4 {
                progress[id] = ProcessingProgress(phase: .writing(part: part, of: 3))
                try? await Task.sleep(for: .milliseconds(700))
            }
            let notes = GeneratedNotes(title: "Pilot check-in",
                summary: "The pilot team has used Hush for a week with no requests to switch back. The only blocker for the second team is exporting action items to Reminders.",
                keyPoints: ["Adoption is strong after the first week.", "Reminders export is the last blocker for the wider rollout."],
                decisions: ["Roll out to the second team once Reminders export ships."],
                actionItems: [.init(title: "Ship Reminders export", owner: "Me", dueText: "Friday"),
                              .init(title: "Schedule the rollout review", owner: "Them", dueText: "next Tuesday")])
            guard let meeting = meeting(id), let template = templates.first(where: { $0.id == meeting.templateID }) else { return }
            update(id) {
                $0.structuredNotes = MeetingNotes(normalizing: notes, context: $0.summaryContext, generatedBy: "Apple on-device")
                if $0.title.hasPrefix("Meeting at ") { $0.title = notes.title }
                $0.state = .ready
            }
            let text = template.render(self.meeting(id)?.structuredNotes ?? MeetingNotes(normalizing: notes, context: meeting.summaryContext, generatedBy: "Apple on-device"))
            demoMarkdown[id] = text
            if selectedID == id { markdown = text }
            tasks = demoTasks()
            activeJob = nil; progress[id] = nil
            show(.success, "Notes ready", detail: self.meeting(id)?.title)
        }
    }

    private static func isoDay(_ offset: Int) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: .now) ?? .now)
    }

    func demoTasks() -> [NoteTask] {
        if let selectedID, !markdown.isEmpty { demoMarkdown[selectedID] = markdown }
        return meetings.flatMap { NotesMarkdown.tasks(in: demoMarkdown[$0.id] ?? "", meetingID: $0.id) }
    }

    func loadDemo(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        markdown = demoMarkdown[id] ?? ""
        let them = meeting.attendees?.first?.components(separatedBy: " ").first ?? "Sam"
        displayedTranscript = Transcript(startedAt: meeting.startedAt, locale: "en-US", segments: [
            .init(speaker: .me, start: 12, end: 29, text: "Thanks for making the time. I want to walk through where we landed and make sure we agree on the next step."),
            .init(speaker: .them, start: 30, end: 52, text: "Sounds good. From our side the main thing is that nothing leaves the laptop. If that holds, \(them == "Sam" ? "we" : "the team") can move quickly."),
            .init(speaker: .me, start: 58, end: 73, text: "It does. Speech and notes both run on the Mac by default. I'll send the security overview tomorrow."),
            .init(speaker: .them, start: 76, end: 95, text: "Perfect. Then let's plan a two-week pilot with eight people and review it together at the end."),
            .init(speaker: .me, start: 99, end: 110, text: "Great. I'll schedule the kickoff for next week and bring the checklist.")
        ])
    }
}
