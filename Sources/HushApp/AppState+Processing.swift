import AppKit
import SwiftUI
import HushKit
import MuesliCore

extension AppState {
    // MARK: Queue

    /// Asks before sending a meeting to a cloud provider. Returns false if the person declines.
    /// For a question (Ask), only the notes provider matters: questions never go to transcription.
    func confirmProviders(askingAbout question: Meeting? = nil) -> Bool {
        let providers = preferences.providers
        guard question == nil ? providers.leavesMac : !providers.notes.isOnDevice, !isDemo else { return true }
        let alert = NSAlert(); alert.messageText = "Send this meeting to \(providers.destinations.joined(separator: " and "))?"
        alert.informativeText = providers.dataFlow
        if let question {
            let name = providers.notes == .compatible ? (providers.notesHost ?? "your server") : providers.notes.name
            alert.messageText = "Send questions about this meeting to \(name)?"
            let sent = question.includesSideNotes && !question.userNotes.isEmpty
                ? "this meeting's notes, your side notes and the parts of its transcript that match" : "this meeting's notes and the parts of its transcript that match"
            alert.informativeText = "Each question goes to \(name) with \(sent). Answers stay on this page unless you add one to your side notes."
        }
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Transcribes (if needed) and writes notes again. Safe to call while recording.
    func retry(_ id: UUID) {
        guard meeting(id) != nil, !isQueued(id), currentID != id else { return }
        guard confirmProviders() else { return }
        DiagnosticLog.shared.record(.retryStarted)
        enqueue(id, confirmed: true)
    }

    /// Writes notes again, asking first when they were edited by hand.
    func regenerate(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        if meeting.notesEdited == true && !confirmReplaceEdited() { return }
        retry(id)
    }

    private func confirmReplaceEdited() -> Bool {
        guard !isDemo else { return true }
        let alert = NSAlert(); alert.messageText = "Replace your edited notes?"
        alert.informativeText = "Hush will write new notes from the transcript. Your side notes and the transcript stay as they are."
        alert.addButton(withTitle: "Replace notes"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func changeTemplate(_ templateID: String, for id: UUID) {
        guard let meeting = meeting(id), meeting.templateID != templateID, !isQueued(id), currentID != id else { return }
        if meeting.notesEdited == true && !confirmReplaceEdited() { return }
        update(id) { $0.templateID = templateID; $0.notesEdited = nil }
        persist(id)
        // Show the new layout at once from the notes already written; the model then refines it.
        if let notes = meeting.structuredNotes, let template = templates.first(where: { $0.id == templateID }) {
            let text = Self.carryingChecks(from: selectedID == id ? markdown : "", into: template.render(notes))
            if selectedID == id { markdown = text }
            if isDemo { tasks = demoTasks() } else { Task { try? await saveContent(id, markdown: text); await refreshTasks() } }
        }
        guard !isDemo, meeting.transcriptionFinal else { return }
        retry(id)
    }

    func enqueue(_ id: UUID, confirmed: Bool = false) {
        guard meeting(id) != nil, !isQueued(id) else { return }
        guard confirmed || confirmProviders() else { return }
        queue.append(id)
        jobProviders[id] = preferences.providers
        progress[id] = ProcessingProgress(phase: .waiting)
        update(id) { $0.state = $0.transcriptionFinal ? .writing : .transcribing; $0.failure = nil }
        persist(id)
        pump()
    }

    func cancelProcessing(_ id: UUID? = nil) {
        let target = id ?? activeJob
        guard let target else { return }
        if activeJob == target { processingTask?.cancel(); return }
        if let index = queue.firstIndex(of: target) {
            queue.remove(at: index); progress[target] = nil; jobProviders[target] = nil
            Task { await fail(target, CancellationError()) }
        }
    }

    func pump() {
        guard activeJob == nil, !maintenance, !queue.isEmpty else {
            if activeJob == nil && queue.isEmpty, let processingActivity { ProcessInfo.processInfo.endActivity(processingActivity); self.processingActivity = nil }
            return
        }
        let id = queue.removeFirst()
        activeJob = id
        if processingActivity == nil {
            processingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Writing meeting notes")
        }
        processingTask = Task {
            do { try await process(id) }
            catch { await fail(id, error) }
            activeJob = nil; processingTask = nil; progress[id] = nil; jobProviders[id] = nil
            if let store { storageSize = await store.size() }
            pump()
        }
    }

    // MARK: Work

    private func process(_ id: UUID) async throws {
        guard !isDemo else { try await Task.sleep(for: .seconds(1)); update(id) { $0.state = .ready }; return }
        guard let meeting = meeting(id) else { throw HushError.message("This meeting couldn't be found.") }
        guard await flushWrites() else { throw HushError.message("Save your side notes before updating the notes.") }
        if !meeting.transcriptionFinal {
            update(id) { $0.state = .transcribing }
            progress[id] = ProcessingProgress(phase: .transcribing(nil))
            let transcript = try await transcribeFiles(meeting)
            try Task.checkCancellation()
            update(id) { $0.transcriptionFinal = true; $0.failure = nil }
            try await saveContent(id, transcript: transcript)
            if selectedID == id { displayedTranscript = transcript }
            if let store {
                if preferences.deleteAudio { try await store.deleteAudio(id) } else { try await store.protectAudio(id) }
            }
        } else if let store, preferences.deleteAudio, await store.hasAudio(id), meeting.structuredNotes == nil {
            // A fresh Apple Speech recording: its tracks are no longer needed.
            try await store.deleteAudio(id)
        } else if let store {
            try await store.protectAudio(id)
        }
        try await generate(id)
    }

    private func transcribeFiles(_ meeting: Meeting) async throws -> Transcript {
        guard let store else { throw HushError.message("The meeting store isn't ready.") }
        defer { Task { await store.discardProcessingAudio(meeting.id) } }
        var tracks: [FileTranscriber.Track] = []
        for speaker in [Speaker.me, .them] {
            guard let url = try await store.processingAudio(meeting.id, name: speaker.rawValue + ".wav") else { continue }
            tracks.append(.init(speaker: speaker, url: url, offset: meeting.audioOffsets?[speaker.rawValue] ?? 0))
        }
        guard !tracks.isEmpty else {
            if await store.hasTranscript(meeting.id), let saved = try? await store.transcript(meeting.id), !saved.segments.isEmpty { return saved }
            throw HushError.message("This meeting's audio is no longer available, so it can't be transcribed again.")
        }
        let id = meeting.id
        return try await FileTranscriber(service: (jobProviders[id] ?? preferences.providers).transcription).transcribe(tracks, locale: meeting.locale, startedAt: meeting.startedAt) { value in
            Task { @MainActor [weak self] in self?.progress[id] = ProcessingProgress(phase: .transcribing(value)) }
        }
    }

    private func generate(_ id: UUID) async throws {
        guard let store, let snapshot = meeting(id) else { return }
        let transcript = try await store.transcript(id)
        guard !transcript.segments.isEmpty else {
            throw HushError.message("No speech was transcribed. Check microphone and system audio permissions, then try a new recording.")
        }
        update(id) { $0.state = .writing }
        persist(id)
        reloadTemplates()
        guard let template = templates.first(where: { $0.id == snapshot.templateID }) ?? templates.first else { throw HushError.message("No note template is available.") }
        let providers = jobProviders[id] ?? preferences.providers
        let base = NotesProviders.make(providers)
        let context = snapshot.summaryContext
        let parts = MeetingSummarizer.plannedParts(transcript, context: context, modelBudget: await base.transcriptCharacterBudget)
        progress[id] = ProcessingProgress(phase: .writing(part: 1, of: parts))
        let paced = PacedNotesGenerator(base: TemplateNotesProvider(base: base, instruction: template.instruction), perRequest: PacedNotesGenerator.limit(for: providers.notes)) { count in
            Task { @MainActor [weak self] in self?.progress[id] = ProcessingProgress(phase: .writing(part: count, of: parts)) }
        }
        DiagnosticLog.shared.record(.notesStarted, count: parts)
        try await paced.preflight()
        let result = try await MeetingSummarizer(generator: paced, enforceMergeBudget: true).summarize(transcript, context: context)
        try Task.checkCancellation()
        DiagnosticLog.shared.record(.notesFinished, count: parts)
        let previousNotes = selectedID == id ? markdown : ((try? await store.markdown(id)) ?? "")
        let text = Self.carryingChecks(from: previousNotes, into: template.render(result.notes))
        // Merge into the latest copy: side notes typed while the model worked are kept.
        update(id) {
            $0.structuredNotes = result.notes
            // Only a placeholder title is replaced; names from the calendar or the person stay.
            let placeholder = snapshot.title.hasPrefix("Meeting at ") || snapshot.title == "Untitled meeting"
            if $0.title == snapshot.title, placeholder, snapshot.calendarEventID == nil { $0.title = result.notes.title }
            $0.notesContextDigest = snapshot.contextDigest
            $0.state = .ready; $0.failure = nil; $0.notesEdited = nil
        }
        try await saveContent(id, markdown: text)
        if selectedID == id { markdown = text; displayedTranscript = transcript }
        await refreshTasks()
        clearRecoveryCount(id)
        notify(title: "Notes ready", body: meeting(id)?.title ?? "Your meeting notes are waiting in Hush.", id: id.uuidString)
    }

    /// Keeps checked action items checked when notes are rewritten with the same wording.
    static func carryingChecks(from old: String, into new: String) -> String {
        let done = Set(NotesMarkdown.tasks(in: old, meetingID: UUID()).filter(\.done).map { $0.text.lowercased() })
        guard !done.isEmpty else { return new }
        var result = new
        for task in NotesMarkdown.tasks(in: new, meetingID: UUID()) where !task.done && done.contains(task.text.lowercased()) {
            result = NotesMarkdown.toggling(result, line: task.line) ?? result
        }
        return result
    }

    func fail(_ id: UUID, _ error: Error) async {
        let cancelled = error is CancellationError
        DiagnosticLog.shared.record(cancelled ? .processingCancelled : .processingFailed, error: error)
        let message = cancelled ? "Processing was cancelled. Your recording and transcript are kept, so you can try again any time." : error.localizedDescription
        update(id) { $0.state = .failed; $0.failure = message }
        persist(id)
        try? await store?.protectAudio(id)
        if !cancelled {
            let title = meeting(id)?.title ?? "A meeting"
            show(.error, "Notes couldn't be written for “\(title)”", detail: message, action: selectedID == id ? nil : "Open") { [weak self] in self?.select(id); self?.showMain?() }
        }
    }

    // MARK: Recovery

    /// Meetings left recording or processing when Hush quit are recovered: their audio headers
    /// are repaired, and on-device setups pick up where they stopped.
    func recoverInterrupted() async {
        guard let store else { return }
        let interrupted = meetings.filter { [.recording, .transcribing, .writing].contains($0.state) }
        guard !interrupted.isEmpty else { return }
        var resumed = 0
        for meeting in interrupted {
            let id = meeting.id
            await store.repairAudio(id)
            update(id) { $0.endedAt = $0.endedAt ?? max($0.startedAt, Self.lastModified(of: $0, in: storageURL) ?? $0.startedAt) }
            let key = "hush.recovery." + id.uuidString
            let attempts = UserDefaults.standard.integer(forKey: key)
            let hasAudio = await store.hasAudio(id), hasTranscript = await store.hasTranscript(id)
            let canResume = !preferences.providers.leavesMac && attempts < 2 && (hasAudio || meeting.transcriptionFinal || hasTranscript)
            if canResume {
                UserDefaults.standard.set(attempts + 1, forKey: key)
                DiagnosticLog.shared.record(.recoveryQueued)
                if meeting.state == .recording { update(id) { $0.transcriptionFinal = false } }
                enqueue(id, confirmed: true); resumed += 1
            } else {
                update(id) { $0.state = .failed; $0.failure = "Hush closed before this meeting finished. Your saved audio and transcript are kept. Choose Try again to finish it." }
                persist(id)
            }
        }
        if resumed > 0 {
            show(.info, resumed == 1 ? "Finishing a meeting that was interrupted" : "Finishing \(resumed) interrupted meetings",
                 detail: "Hush closed before the notes were written. They're being written now.")
        }
    }

    private static func lastModified(of meeting: Meeting, in root: URL) -> Date? {
        let folder = root.appendingPathComponent(meeting.id.uuidString)
        return ["me.wav", "them.wav", "transcript.json"].compactMap {
            try? folder.appendingPathComponent($0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    func clearRecoveryCount(_ id: UUID) { UserDefaults.standard.removeObject(forKey: "hush.recovery." + id.uuidString) }
}
