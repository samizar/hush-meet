import Foundation
import EventKit
import Observation
import CoreAudio
import MuesliAudio
import MuesliCore

public struct CalendarMeeting: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var joinURL: URL?
    /// Other invitees' names, without the person using Hush.
    public var attendees: [String]
    public var calendarName: String?
    public init(id: String, title: String, start: Date, end: Date, joinURL: URL? = nil, attendees: [String] = [], calendarName: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.joinURL = joinURL
        self.attendees = attendees; self.calendarName = calendarName
    }
    public var isHappeningNow: Bool { start <= .now && end > .now }
    /// The meeting is about to start or already running, so recording it now makes sense.
    public var isRecordableNow: Bool { start.timeIntervalSinceNow < 15 * 60 && end > .now }
}

@MainActor @Observable
public final class CalendarService {
    public private(set) var meetings: [CalendarMeeting] = []
    public private(set) var hasAccess = false
    public private(set) var error: String?
    private let store = EKEventStore()
    public init() { hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public func requestAccess() async -> Bool {
        do { hasAccess = try await store.requestFullAccessToEvents() }
        catch { self.error = "Calendar access wasn't granted. You can still record any meeting." }
        if hasAccess { refresh() }
        return hasAccess
    }
    /// Sample events for preview mode. Never reads the real calendar.
    public func preview(_ meetings: [CalendarMeeting]) { self.meetings = meetings; hasAccess = true }
    public func refresh() {
        hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard hasAccess else { meetings = []; return }
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86400 * 7), calendars: nil)
        meetings = store.events(matching: predicate).filter { event in
            Self.isMeeting(allDay: event.isAllDay, declined: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                           attendeeCount: event.attendees?.filter { !$0.isCurrentUser }.count ?? 0,
                           hasVideoLink: Self.videoURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")) != nil)
            && event.endDate > now && event.status != .canceled
        }.map { event in
            CalendarMeeting(id: (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + String(Int(event.startDate.timeIntervalSince1970)),
                            title: event.title?.isEmpty == false ? event.title : "Meeting", start: event.startDate, end: event.endDate,
                            joinURL: Self.videoURL(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")),
                            attendees: (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(Self.displayName),
                            calendarName: event.calendar?.title)
        }.sorted { $0.start < $1.start }
    }
    /// Adds items to the default Reminders list. Asks for Reminders access the first time.
    public func addReminders(_ items: [(title: String, notes: String, due: DateComponents?)]) async throws -> Int {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { throw HushError.message("Allow Hush in System Settings → Privacy & Security → Reminders, then try again.") }
        guard let list = store.defaultCalendarForNewReminders() else { throw HushError.message("Choose a default list in Reminders, then try again.") }
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = item.title; reminder.notes = item.notes; reminder.calendar = list
            reminder.dueDateComponents = item.due
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return items.count
    }
    nonisolated static func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") { return name }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        guard let local = address.split(separator: "@").first, !local.isEmpty else { return nil }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" }).map { $0.capitalized }.joined(separator: " ")
    }
    nonisolated public static func isMeeting(allDay: Bool, declined: Bool, attendeeCount: Int, hasVideoLink: Bool) -> Bool {
        !allDay && !declined && (attendeeCount > 0 || hasVideoLink)
    }
    nonisolated public static func videoURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let providers = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "facetime.apple.com", "slack.com", "webex.com"]
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme) else { return false }
            return providers.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

public enum CallDetector {
    /// Core Audio exposes per-process input/output activity without opening the microphone.
    public static func activeApps(terms: [String]) -> [String] {
        let processes = AppSelector(terms).resolve(in: AudioProcesses.list())
        let inputProcesses = processes.filter { process in
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process.objectID, &address, 0, nil, &size, &value) == noErr && value != 0
        }
        return Array(Set(inputProcesses.filter { input in
            processes.contains { output in
                guard output.isProducingAudio else { return false }
                if input.name == output.name { return true }
                guard let first = input.bundleID, let second = output.bundleID else { return false }
                return first == second || first.hasPrefix(second + ".") || second.hasPrefix(first + ".")
            }
        }.map(\.name))).sorted()
    }
    public static func microphoneInUse(terms: [String]) -> Bool {
        AppSelector(terms).resolve(in: AudioProcesses.list()).contains { process in
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var active: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(process.objectID, &address, 0, nil, &size, &active) == noErr && active != 0
        }
    }
}
