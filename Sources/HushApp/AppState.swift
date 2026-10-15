import AppKit
import SwiftUI
import Observation
import ServiceManagement
import Speech
import UserNotifications
import HushKit
import MuesliCore
import MuesliAudio
import MuesliTranscribe

@MainActor @Observable
final class AppState {
    var preferences = Preferences.load() { didSet { if !isDemo { preferences.save() } } }
    var meetings: [Meeting] = []
    var selectedID: UUID?
    var search = ""
    var searchIDs: Set<UUID>?
    var templates: [NoteTemplate] = []
    var markdown = ""
    var displayedTranscript: Transcript?
    var transcriptExpanded = false
    var notice: String?
    var busy = false
    var updater: AppUpdater?
    var currentID: UUID?
    var elapsed: TimeInterval = 0
    var liveNotes = ""
    var activeEvent: CalendarMeeting?
    var storageSize: Int64 = 0
    var storageURL = MeetingStore.defaultRoot
    var locales: [Locale] = []
    var autoOverrides: [String: Bool] = [:] {
        didSet { if !isDemo { UserDefaults.standard.set(autoOverrides, forKey: "hush.autoOverrides") } }
    }
    let capture = CaptureSession()
    let calendar = CalendarService()
    let isDemo: Bool
    @ObservationIgnored var store: MeetingStore?
    @ObservationIgnored var showMain: (() -> Void)?
    @ObservationIgnored var showSettings: (() -> Void)?
    @ObservationIgnored var showCard: ((CalendarMeeting?, String?) -> Void)?
    @ObservationIgnored var dismissCard: (() -> Void)?
    @ObservationIgnored var recordingChanged: ((Bool) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var reminded = Set<String>()
    @ObservationIgnored private var skipped = Set<String>()
    @ObservationIgnored private var autoStarted = Set<String>()
    @ObservationIgnored private var micReleasedAt: Date?
    @ObservationIgnored private var hadCall = false
    @ObservationIgnored private var detectedCall = false
    @ObservationIgnored private var checkpointing = false
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var current: Meeting? { meetings.first { $0.id == currentID } }
    var filteredMeetings: [Meeting] { searchIDs.map { ids in meetings.filter { ids.contains($0.id) } } ?? meetings }
    var canRecord: Bool { !busy && !capture.isRecording && !capture.isPreparing && store != nil }
    var preventsUpdateRestart: Bool { busy || capture.isRecording || capture.isPreparing }
    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if isDemo { seedDemo() }
        else { autoOverrides = UserDefaults.standard.dictionary(forKey: "hush.autoOverrides") as? [String: Bool] ?? [:] }
    }
    func load() async {
        if isDemo { return }
        do {
            if let bookmark = preferences.storageBookmark {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw HushError.message("Hush can't access the selected storage folder. Choose it again in Settings.") }
                scopedURL = url; storageURL = url
                if stale { preferences.storageBookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
            }
            store = try MeetingStore(root: storageURL, encrypted: preferences.encrypted)
            templates = try Templates.load()
            guard let store else { return }
            meetings = try await store.list()
            for i in meetings.indices where [.recording, .transcribing, .writing].contains(meetings[i].state) {
                meetings[i].state = .failed
                meetings[i].endedAt = meetings[i].endedAt ?? meetings[i].startedAt
                meetings[i].failure = "Hush closed before this meeting finished. Retry to recover its saved transcript or audio."
                try await store.save(meetings[i])
            }
            storageSize = await store.size()
            if let first = meetings.first { select(first.id) }
            if preferences.calendarEnabled { calendar.refresh() }
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer?.tolerance = 0.25
            if preferences.calendarEnabled { scheduleNotifications() }
        } catch { notice = error.localizedDescription }
    }
    func select(_ id: UUID) {
        selectedID = id; transcriptExpanded = false; markdown = ""; displayedTranscript = nil
        selectionTask?.cancel()
        guard !isDemo else { loadDemo(id); return }
        selectionTask = Task {
            guard let store else { return }
            let notes = try? await store.markdown(id)
            let transcript = try? await store.transcript(id)
            guard !Task.isCancelled, selectedID == id else { return }
            markdown = notes ?? ""; displayedTranscript = transcript
        }
    }
    func searchChanged() {
        searchTask?.cancel()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { searchIDs = nil; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if isDemo {
                searchIDs = Set(meetings.filter { ($0.title + ($0.structuredNotes?.summary ?? "") + $0.userNotes).localizedCaseInsensitiveContains(query) }.map(\.id))
            } else {
                do {
                    let result = try await store?.search(query) ?? []
                    guard !Task.isCancelled else { return }; searchIDs = result
                } catch { notice = error.localizedDescription }
            }
        }
    }
    func start(event: CalendarMeeting? = nil, automatic: Bool = false) {
        guard canRecord else { return }
        if isDemo { notice = "Preview mode. Open Hush normally to record a meeting."; return }
        if automatic && (!preferences.recordingConsent || preferences.providers.leavesMac) { showCard?(event, nil); return }
        if !preferences.recordingConsent {
            let alert = NSAlert(); alert.messageText = "Before you record"
            alert.informativeText = "Recording others may require their consent. Let everyone know before you start. Headphones help keep the two sides clear."
            alert.addButton(withTitle: "I understand"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            preferences.recordingConsent = true
        }
        if preferences.providers.leavesMac {
            let alert = NSAlert(); alert.messageText = "This meeting uses a provider"
            alert.informativeText = preferences.providers.dataFlow + " Continue with these settings?"
            alert.addButton(withTitle: "Record"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        dismissCard?(); notice = nil; busy = true
        Task {
            guard let store else { busy = false; return }
            var meeting = Meeting(title: event?.title ?? "Untitled meeting", locale: preferences.locale)
            meeting.calendarEventID = event?.id
            do {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                try await store.save(meeting)
                let folder = await store.folder(meeting.id)
                try await capture.start(meeting: meeting, preferences: preferences, folder: folder)
                meeting.startedAt = capture.startedAt ?? .now
                try await store.save(meeting)
                meetings.insert(meeting, at: 0); currentID = meeting.id; selectedID = meeting.id
                activeEvent = event; liveNotes = ""; elapsed = 0; busy = false
                hadCall = CallDetector.microphoneInUse(terms: preferences.captureApps); micReleasedAt = nil
                recordingChanged?(true)
                if preferences.copyConsent { copy("I'm taking notes with Hush.") }
            } catch {
                if capture.isRecording { _ = try? await capture.stop() }
                meeting.state = .failed; meeting.endedAt = .now; meeting.failure = error.localizedDescription
                try? await store.save(meeting)
                meetings = (try? await store.list()) ?? meetings
                notice = error.localizedDescription; busy = false
            }
        }
    }
    func stop() {
        guard capture.isRecording, let id = currentID, let store else { return }
        busy = true; recordingChanged?(false)
        update(id) { $0.endedAt = .now; $0.userNotes = liveNotes; $0.state = .transcribing }
        Task {
            do {
                guard let snapshot = meetings.first(where: { $0.id == id }) else { return }
                try await store.save(snapshot, transcript: capture.transcript)
                var transcript = try await capture.stop()
                update(id) { $0.audioOffsets = capture.audioOffsets }
                if preferences.providers.transcription != .apple {
                    var aligned = snapshot; aligned.audioOffsets = capture.audioOffsets
                    transcript = try await transcribeFiles(id: id, meeting: aligned)
                }
                try await finishTranscription(id: id, transcript: transcript)
                try await generate(id)
            } catch { await fail(id, error) }
            currentID = nil; activeEvent = nil; busy = false
            storageSize = await store.size()
        }
    }
    private func transcribeFiles(id: UUID, meeting: Meeting) async throws -> Transcript {
        guard let store else { throw HushError.message("The meeting store isn't ready.") }
        var transcript = Transcript(startedAt: meeting.startedAt, locale: meeting.locale)
        for speaker in [Speaker.me, .them] {
            let offset = meeting.audioOffsets?[speaker.rawValue] ?? 0
            guard let bytes = try await store.audioData(id, name: speaker.rawValue + ".wav"), bytes.count > 44 else { continue }
            let temporary = await store.folder(id).appendingPathComponent(".retry-" + speaker.rawValue + ".wav")
            try bytes.write(to: temporary, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if preferences.providers.transcription == .apple {
                let locale = try await StreamTranscriber.prepare(locale: Locale(identifier: meeting.locale))
                for try await segment in StreamTranscriber(speaker: speaker, locale: locale).transcribe(try AudioFileSource.chunks(url: temporary)) {
                    var aligned = segment; aligned.start += offset; aligned.end += offset; transcript.append(aligned)
                }
            } else {
                let provider = CloudTranscriptionProvider(service: preferences.providers.transcription)
                for try await (wav, start, duration) in try WaveAudio.chunks(file: temporary) {
                    if wav.dropFirst(44).allSatisfy({ $0 == 0 }) { continue }
                    let text = try await provider.transcribe(wav: wav, locale: meeting.locale)
                    transcript.append(TranscriptSegment(speaker: speaker, start: start + offset, end: start + duration + offset, text: text))
                }
            }
        }
        return transcript
    }
    private func finishTranscription(id: UUID, transcript: Transcript) async throws {
        guard let store else { return }
        update(id) { $0.transcriptionFinal = true; $0.state = .writing; $0.failure = nil }
        if let meeting = meetings.first(where: { $0.id == id }) { try await store.save(meeting, transcript: transcript) }
        if preferences.deleteAudio { try await store.deleteAudio(id) }
        else { try await store.protectAudio(id) }
        if selectedID == id { displayedTranscript = transcript }
    }
    func retry(_ id: UUID) {
        guard !busy, !capture.isRecording else { return }
        if preferences.providers.leavesMac {
            let alert = NSAlert(); alert.messageText = "Use the selected providers?"; alert.informativeText = preferences.providers.dataFlow
            alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = true
        Task {
            do {
                guard let meeting = meetings.first(where: { $0.id == id }) else { busy = false; return }
                if !meeting.transcriptionFinal {
                    update(id) { $0.state = .transcribing }
                    let transcript = try await transcribeFiles(id: id, meeting: meeting)
                    try await finishTranscription(id: id, transcript: transcript)
                }
                try await generate(id)
            } catch { await fail(id, error) }
            busy = false
        }
    }
    func changeTemplate(_ templateID: String, for id: UUID) {
        guard !busy && !capture.isRecording else { return }
        update(id) { $0.templateID = templateID }
        if isDemo, let notes = selected?.structuredNotes, let template = templates.first(where: { $0.id == templateID }) { markdown = template.render(notes); return }
        retry(id)
    }
    private func generate(_ id: UUID) async throws {
        guard let store, var meeting = meetings.first(where: { $0.id == id }) else { return }
        let transcript = try await store.transcript(id)
        guard !transcript.segments.isEmpty else { throw HushError.message("No speech was transcribed. Check microphone and system audio permissions, then try a new recording.") }
        meeting.state = .writing; update(id) { $0.state = .writing }
        try await store.save(meeting)
        templates = try Templates.load()
        guard let template = templates.first(where: { $0.id == meeting.templateID }) ?? templates.first else { throw HushError.message("No note template is available.") }
        let provider: any NotesGenerator = preferences.providers.notes == .apple ? AppleNotesProvider() : CloudNotesProvider(configuration: preferences.providers)
        try await provider.preflight()
        let result = try await MeetingSummarizer(generator: TemplateNotesProvider(base: provider, instruction: template.instruction), enforceMergeBudget: true).summarize(transcript,
            context: MeetingContext(title: meeting.title, start: meeting.startedAt, userNotes: meeting.userNotes))
        meeting.structuredNotes = result.notes; meeting.title = result.notes.title
        meeting.state = .ready; meeting.failure = nil
        let text = template.render(result.notes)
        try await store.save(meeting, markdown: text)
        update(id) { $0 = meeting }
        if selectedID == id { markdown = text; displayedTranscript = transcript }
        notify(title: "Notes ready", body: "Your meeting notes are waiting in Hush.", id: id.uuidString)
    }
    private func fail(_ id: UUID, _ error: Error) async {
        update(id) { $0.state = .failed; $0.failure = error.localizedDescription }
        if let meeting = meetings.first(where: { $0.id == id }) {
            try? await store?.save(meeting, transcript: !meeting.transcriptionFinal && capture.transcript?.startedAt == meeting.startedAt ? capture.transcript : nil)
            try? await store?.protectAudio(id)
        }
        notice = error.localizedDescription
    }
    func update(_ id: UUID, _ body: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }; body(&meetings[index])
    }
    func rename(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update(id) { $0.title = String(clean.prefix(200)) }
        if let meeting = meetings.first(where: { $0.id == id }) { Task { try? await store?.save(meeting) } }
    }
    func delete(_ id: UUID) {
        guard !busy && !capture.isRecording else { return }
        let alert = NSAlert(); alert.messageText = "Delete this meeting?"; alert.informativeText = "Its notes, transcript, and saved audio will be deleted from this Mac."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                if !isDemo { try await store?.delete(id) }
                meetings.removeAll { $0.id == id }
                selectedID = nil; markdown = ""; displayedTranscript = nil
                if let next = meetings.first { select(next.id) }
                storageSize = await store?.size() ?? 0
            } catch { notice = error.localizedDescription }
        }
    }
    func deleteAll() {
        guard !busy && !capture.isRecording else { return }
        let alert = NSAlert(); alert.messageText = "Delete all meetings?"; alert.informativeText = "This permanently deletes every meeting, transcript, note, and audio recording in Hush."
        alert.alertStyle = .warning; alert.addButton(withTitle: "Delete all meetings"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                if !isDemo { try await store?.deleteAll() }
                meetings = []; selectedID = nil; markdown = ""; displayedTranscript = nil; storageSize = 0
            } catch { notice = error.localizedDescription }
        }
    }
    func setEncryption(_ enabled: Bool) {
        guard !busy && !capture.isRecording else { return }
        busy = true
        Task {
            do { try await store?.setEncryption(enabled); preferences.encrypted = enabled }
            catch { notice = error.localizedDescription }
            busy = false
        }
    }
    func chooseStorage() {
        guard !busy && !capture.isRecording else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = "Choose the folder Hush should use for new and existing meetings. Your current files will be moved into it."
        guard panel.runModal() == .OK, let url = panel.url, url.standardizedFileURL != storageURL.standardizedFileURL else { return }
        let access = url.startAccessingSecurityScopedResource()
        busy = true
        Task {
            do {
                guard !url.resolvingSymlinksInPath().path.hasPrefix(storageURL.resolvingSymlinksInPath().path + "/") else {
                    throw HushError.message("Choose a folder outside the current meeting store.")
                }
                let existing = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard existing.isEmpty else { throw HushError.message("Choose an empty folder for your meetings.") }
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let originals = try FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
                var copied: [URL] = []
                var committed = false
                do {
                    for original in originals {
                        let target = url.appendingPathComponent(original.lastPathComponent)
                        try FileManager.default.copyItem(at: original, to: target); copied.append(target)
                    }
                    let newStore = try MeetingStore(root: url, encrypted: preferences.encrypted)
                    _ = try await newStore.list()
                    store = newStore; preferences.storageBookmark = bookmark
                    scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = access ? url : nil
                    storageURL = url
                    committed = true
                    for original in originals {
                        do { try FileManager.default.removeItem(at: original) }
                        catch { notice = "Your meetings were moved. A duplicate remains in the previous folder and can be removed in Finder." }
                    }
                } catch {
                    if !committed { for copiedURL in copied { try? FileManager.default.removeItem(at: copiedURL) } }
                    throw error
                }
            } catch { if access { url.stopAccessingSecurityScopedResource() }; notice = error.localizedDescription }
            busy = false
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { notice = "Couldn't change launch at login. Check System Settings → General → Login Items." }
    }
    func enableCalendar() {
        Task {
            preferences.calendarEnabled = await calendar.requestAccess()
            if preferences.calendarEnabled {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                scheduleNotifications()
            }
        }
    }
    func skip(_ event: CalendarMeeting?) {
        if let event { skipped.insert(event.id); UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [event.id]) }
        else { detectedCall = true }
        dismissCard?()
    }
    func scheduleNotifications() {
        guard preferences.calendarEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for event in calendar.meetings where event.start.timeIntervalSinceNow > 60 && !skipped.contains(event.id) {
            let content = UNMutableNotificationContent(); content.title = "Meeting in one minute"
            content.body = event.title; content.categoryIdentifier = "MEETING"; content.userInfo = ["event": event.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: event.start.timeIntervalSinceNow - 60, repeats: false)
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: trigger))
        }
    }
    func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.userInfo = ["meeting": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "notes-" + id, content: content, trigger: nil))
    }
    func copy(_ string: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string) }
    private func tick() {
        tickCount += 1
        if capture.isRecording {
            elapsed = Date.now.timeIntervalSince(capture.startedAt ?? .now)
            if tickCount % 15 == 0, !checkpointing, let meeting = current {
                checkpointing = true
                var copy = meeting; copy.userNotes = liveNotes; copy.audioOffsets = capture.audioOffsets
                Task {
                    do { try await store?.save(copy, transcript: capture.transcript) }
                    catch { notice = "Couldn't save the latest transcript. Check available disk space." }
                    checkpointing = false
                }
            }
        }
        if tickCount % 60 == 0, preferences.calendarEnabled { calendar.refresh(); scheduleNotifications() }
        guard tickCount % 5 == 0 else { return }
        let callApps = preferences.detectCalls || capture.isRecording ? CallDetector.activeApps(terms: preferences.captureApps) : []
        if capture.isRecording {
            let micActive = CallDetector.microphoneInUse(terms: preferences.captureApps)
            capture.checkSilence(duringCall: !callApps.isEmpty)
            if micActive { hadCall = true; micReleasedAt = nil }
            else if hadCall {
                micReleasedAt = micReleasedAt ?? .now
                if Date.now.timeIntervalSince(micReleasedAt!) >= 60 { stop(); return }
            }
            if let event = activeEvent, Date.now > event.end.addingTimeInterval(600) { stop() }
            return
        }
        guard !busy && !capture.isPreparing else { return }
        if preferences.calendarEnabled {
            for event in calendar.meetings where !skipped.contains(event.id) && !autoStarted.contains(event.id) {
                let until = event.start.timeIntervalSinceNow
                if until <= 60 && until > 0 && !reminded.contains(event.id) {
                    reminded.insert(event.id); showCard?(event, nil)
                }
                if until <= 0 && until > -15 && (autoOverrides[event.id] ?? preferences.autoRecord) {
                    autoStarted.insert(event.id); start(event: event, automatic: true); return
                }
            }
        }
        let armed = calendar.meetings.contains { $0.start.timeIntervalSinceNow < 120 && $0.end > .now }
        if preferences.detectCalls && !callApps.isEmpty && !armed && !detectedCall {
            detectedCall = true; showCard?(nil, callApps.first)
        }
        if callApps.isEmpty { detectedCall = false }
    }
}
