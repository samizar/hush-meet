import AppKit
import SwiftUI
import UserNotifications
import HushKit
import MuesliCore
import MuesliAudio
import MuesliTranscribe

extension AppState {
    /// Free space below this refuses to start; below `lowDiskWarning` it warns. Two 16 kHz
    /// tracks use about 230 MB an hour.
    static let minimumDisk: Int64 = 300_000_000
    static let lowDiskWarning: Int64 = 1_500_000_000

    func toggleRecording() { capture.isRecording ? stop() : start() }

    func start(event: CalendarMeeting? = nil, automatic: Bool = false) {
        guard canRecord else { return }
        if isDemo { startDemoRecording(event); return }
        if automatic && (!preferences.recordingConsent || preferences.providers.leavesMac) { showCard?(event, nil); return }
        if !preferences.recordingConsent {
            let alert = NSAlert(); alert.messageText = "Before your first recording"
            alert.informativeText = "Recording other people may require their consent. Let everyone know before you start.\n\nHeadphones keep your voice and theirs on separate, clearer tracks."
            alert.addButton(withTitle: "I understand"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            preferences.recordingConsent = true
        }
        if preferences.providers.leavesMac {
            let alert = NSAlert(); alert.messageText = "This meeting will use \(preferences.providers.destinations.joined(separator: " and "))"
            alert.informativeText = preferences.providers.dataFlow + "\n\nYou can change this in Settings → AI Models."
            alert.addButton(withTitle: "Record"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if let free = Self.freeSpace(at: storageURL) {
            if free < Self.minimumDisk {
                DiagnosticLog.shared.record(.lowDiskSpace)
                show(.error, "Not enough space to record", detail: "Free up some disk space, then try again. Hush needs about 250 MB per hour.")
                return
            }
            if free < Self.lowDiskWarning { show(.warning, "Disk space is low", detail: "Hush can record for about \(max(1, Int(free / 250_000_000))) hours.") }
        }
        dismissCard?(); isStarting = true
        Task {
            defer { isStarting = false }
            guard let store else { return }
            var meeting = Meeting(title: event?.title ?? Self.defaultTitle(), locale: preferences.locale)
            meeting.calendarEventID = event?.id
            meeting.attendees = event.map(\.attendees).flatMap { $0.isEmpty ? nil : $0 }
            meeting.joinURL = event?.joinURL
            do {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                try await store.save(meeting)
                let folder = await store.folder(meeting.id)
                try await capture.start(meeting: meeting, preferences: preferences, folder: folder)
                meeting.startedAt = capture.startedAt ?? .now
                try await store.save(meeting)
                meetings.insert(meeting, at: 0); currentID = meeting.id
                route = .meeting(meeting.id); markdown = ""; displayedTranscript = nil
                activeEvent = event; liveNotes = ""; elapsed = 0
                hadCall = CallDetector.microphoneInUse(terms: preferences.captureApps); micReleasedAt = nil
                recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording a meeting")
                recordingChanged?(true)
                if preferences.copyConsent { copy("I'm taking notes with Hush.") }
            } catch {
                if capture.isRecording { _ = try? await capture.stop() }
                try? await store.delete(meeting.id)
                showStartError(error)
            }
        }
    }

    private func showStartError(_ error: Error) {
        if let capture = error as? MicrophoneCapture.CaptureError, capture == .accessDenied {
            show(.error, "Hush can't use the microphone", detail: "Allow Hush in Privacy & Security → Microphone.", action: "Open Settings") {
                NSWorkspace.shared.open(CaptureSession.microphoneSettings)
            }
        } else if let speech = error as? StreamTranscriber.TranscribeError, case .unsupportedLocale = speech {
            show(.error, "Apple Speech doesn't support this language", detail: "Choose another language, or a cloud speech provider in Settings → AI Models.", action: "Open Settings") { [weak self] in
                self?.showSettings?(.models)
            }
        } else {
            show(.error, "Recording couldn't start", detail: error.localizedDescription)
        }
    }

    static func defaultTitle(at date: Date = .now) -> String {
        "Meeting at " + date.formatted(date: .omitted, time: .shortened)
    }

    func stop(reason: String? = nil) {
        guard capture.isRecording, let id = currentID, !isStopping else { return }
        if isDemo { stopDemoRecording(id); return }
        isStopping = true
        recordingChanged?(false)
        if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
        recordingActivity = nil
        update(id) { $0.endedAt = .now; $0.userNotes = liveNotes; $0.state = .transcribing }
        persist(id)
        Task {
            defer { isStopping = false; currentID = nil; activeEvent = nil }
            do {
                let finished = try await capture.stop()
                update(id) { $0.audioOffsets = capture.audioOffsets }
                if preferences.providers.transcription == .apple {
                    update(id) { $0.transcriptionFinal = true }
                    try await saveContent(id, transcript: finished)
                }
            } catch {
                // The live transcript didn't finish. The saved tracks are transcribed again by the queue.
                update(id) { $0.audioOffsets = capture.audioOffsets; $0.transcriptionFinal = false }
                if let partial = capture.transcript, !partial.segments.isEmpty { try? await saveContent(id, transcript: partial) }
            }
            if let reason { show(.info, reason) }
            enqueue(id, confirmed: true)
        }
    }

    /// Writes transcript or notes files, then the latest meeting record.
    func saveContent(_ id: UUID, transcript: Transcript? = nil, markdown text: String? = nil) async throws {
        guard !isDemo, let store, let meeting = meeting(id) else { return }
        try await store.save(meeting, transcript: transcript, markdown: text)
        persist(id)
    }

    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Calendar

    func enableCalendar() {
        Task {
            preferences.calendarEnabled = await calendar.requestAccess()
            if preferences.calendarEnabled {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                scheduleNotifications()
            } else {
                show(.warning, "Calendar access is off", detail: "Allow Hush in Privacy & Security → Calendars.", action: "Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            }
        }
    }
    func join(_ event: CalendarMeeting) {
        if let url = event.joinURL { NSWorkspace.shared.open(url) }
        start(event: event)
    }
    func skip(_ event: CalendarMeeting?) {
        if let event { skipped.insert(event.id); UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [event.id]) }
        else { detectedCall = true }
        dismissCard?()
    }
    func scheduleNotifications() {
        guard preferences.calendarEnabled, !isDemo else { return }
        let center = UNUserNotificationCenter.current()
        let ids = calendar.meetings.map(\.id)
        Task {
            let pending = await center.pendingNotificationRequests()
            let stale = pending.map(\.identifier).filter { !$0.hasPrefix("notes-") && !ids.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        guard preferences.meetingReminders else { center.removePendingNotificationRequests(withIdentifiers: ids); return }
        for event in calendar.meetings where event.start.timeIntervalSinceNow > 60 && !skipped.contains(event.id) {
            let content = UNMutableNotificationContent(); content.title = event.title
            content.body = "Starts in one minute." + (event.joinURL != nil ? " Join and record from here." : "")
            content.categoryIdentifier = "MEETING"; content.userInfo = ["event": event.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: event.start.timeIntervalSinceNow - 60, repeats: false)
            center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: trigger))
        }
    }
    func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.userInfo = ["meeting": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "notes-" + id, content: content, trigger: nil))
    }

    // MARK: Clock

    func tick() {
        tickCount += 1
        if capture.isRecording {
            elapsed = Date.now.timeIntervalSince(capture.startedAt ?? .now)
            if tickCount % 15 == 0, !checkpointing, let meeting = current, let store {
                checkpointing = true
                var copy = meeting; copy.userNotes = liveNotes; copy.audioOffsets = capture.audioOffsets
                let transcript = capture.transcript
                Task {
                    do { try await store.save(copy, transcript: transcript) }
                    catch { show(.warning, "Couldn't save the latest transcript", detail: "Check available disk space.") }
                    checkpointing = false
                }
            }
            if tickCount % 60 == 0, let free = Self.freeSpace(at: storageURL), free < Self.minimumDisk / 2 {
                stop(reason: "Recording stopped because your disk is almost full.")
                return
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
                if let released = micReleasedAt, Date.now.timeIntervalSince(released) >= 60 { stop(reason: "The call ended, so Hush stopped recording."); return }
            }
            if let event = activeEvent, Date.now > event.end.addingTimeInterval(600) { stop(reason: "The meeting's scheduled time ended, so Hush stopped recording.") }
            return
        }
        guard canRecord else { return }
        if preferences.calendarEnabled {
            for event in calendar.meetings where !skipped.contains(event.id) && !autoStarted.contains(event.id) {
                let until = event.start.timeIntervalSinceNow
                if preferences.meetingReminders && until <= 60 && until > 0 && !reminded.contains(event.id) {
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
