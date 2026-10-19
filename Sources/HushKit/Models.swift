import Foundation
import CryptoKit
import MuesliCore

public enum MeetingState: String, Codable, Sendable {
    case recording, transcribing, writing, ready, failed
}

public struct Meeting: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var locale: String
    public var templateID: String
    public var userNotes: String
    public var state: MeetingState
    public var failure: String?
    public var calendarEventID: String?
    public var structuredNotes: MeetingNotes?
    public var transcriptionFinal: Bool
    public var audioOffsets: [String: TimeInterval]?
    public var useSideNotesAsContext: Bool?
    public var notesContextDigest: String?
    // 2.0 additions are optional so older meeting files keep decoding.
    /// Invitees from the calendar event, shown on the page and given to the notes model.
    public var attendees: [String]?
    /// The person edited the notes by hand. Regenerating asks before replacing them.
    public var notesEdited: Bool?
    /// Display names for the two channels, for example "Them" → "Priya".
    public var speakerNames: [String: String]?
    /// The video-call link from the calendar event.
    public var joinURL: URL?

    public init(id: UUID = UUID(), title: String = "Untitled meeting", startedAt: Date = .now,
                locale: String = Locale.current.identifier, templateID: String = "quick") {
        self.id = id; self.title = title; self.startedAt = startedAt; self.locale = locale
        self.templateID = templateID; userNotes = ""; state = .recording; transcriptionFinal = false
    }

    /// Tolerates missing or unexpected values so one odd field never hides a meeting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled meeting"
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        endedAt = (try? c.decodeIfPresent(Date.self, forKey: .endedAt))
        locale = (try? c.decodeIfPresent(String.self, forKey: .locale)) ?? Locale.current.identifier
        templateID = (try? c.decodeIfPresent(String.self, forKey: .templateID)) ?? "quick"
        userNotes = (try? c.decodeIfPresent(String.self, forKey: .userNotes)) ?? ""
        state = (try? c.decodeIfPresent(MeetingState.self, forKey: .state)) ?? .failed
        failure = (try? c.decodeIfPresent(String.self, forKey: .failure))
        calendarEventID = (try? c.decodeIfPresent(String.self, forKey: .calendarEventID))
        structuredNotes = (try? c.decodeIfPresent(MeetingNotes.self, forKey: .structuredNotes))
        transcriptionFinal = (try? c.decodeIfPresent(Bool.self, forKey: .transcriptionFinal)) ?? false
        audioOffsets = (try? c.decodeIfPresent([String: TimeInterval].self, forKey: .audioOffsets))
        useSideNotesAsContext = (try? c.decodeIfPresent(Bool.self, forKey: .useSideNotesAsContext))
        notesContextDigest = (try? c.decodeIfPresent(String.self, forKey: .notesContextDigest))
        attendees = (try? c.decodeIfPresent([String].self, forKey: .attendees))
        notesEdited = (try? c.decodeIfPresent(Bool.self, forKey: .notesEdited))
        speakerNames = (try? c.decodeIfPresent([String: String].self, forKey: .speakerNames))
        joinURL = (try? c.decodeIfPresent(URL.self, forKey: .joinURL))
    }

    public var duration: TimeInterval { max(0, (endedAt ?? .now).timeIntervalSince(startedAt)) }
    public var includesSideNotes: Bool { useSideNotesAsContext ?? true }
    public var contextDigest: String {
        SHA256.hash(data: Data((includesSideNotes ? userNotes : "").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var sideNotesChanged: Bool { structuredNotes != nil && notesContextDigest.map { $0 != contextDigest } == true }
    public var summaryContext: MeetingContext {
        MeetingContext(title: title, start: startedAt, userNotes: includesSideNotes ? userNotes : nil, attendees: attendees ?? [])
    }
    public var isProcessing: Bool { state == .transcribing || state == .writing }
    /// The first sentence of the summary, for list previews.
    public var preview: String? {
        guard let summary = structuredNotes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        return summary
    }
    public func name(for speaker: Speaker) -> String {
        let custom = speakerNames?[speaker.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom?.isEmpty == false ? custom! : speaker.label
    }
}

public enum TranscriptionService: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, deepgram, elevenlabs, gemini, openai
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .apple: "Apple Speech"
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs Scribe"
        case .gemini: "Gemini"
        case .openai: "OpenAI"
        }
    }
    public var host: String? {
        switch self {
        case .apple: nil
        case .deepgram: "api.deepgram.com"
        case .elevenlabs: "api.elevenlabs.io"
        case .gemini: "generativelanguage.googleapis.com"
        case .openai: "api.openai.com"
        }
    }
}

public enum NotesService: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, ollama, lmstudio, anthropic, openai, gemini, compatible
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .apple: "Apple on-device"
        case .ollama: "Ollama (local)"
        case .lmstudio: "LM Studio / llama.cpp (local)"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .compatible: "OpenAI-compatible"
        }
    }
    public var defaultModel: String {
        switch self {
        case .apple, .ollama, .lmstudio: ""
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-4.1-mini"
        case .gemini: "gemini-3.8-flash"
        case .compatible: ""
        }
    }
    public var isLocalServer: Bool { self == .ollama || self == .lmstudio }
    public var isOnDevice: Bool { self == .apple || isLocalServer }
    public var defaultLocalURL: String { self == .ollama ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1" }
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var transcription: TranscriptionService = .apple
    public var notes: NotesService = .apple
    public var model: String = ""
    public var compatibleURL: String = "https://localhost:11434/v1"
    public var localURL: String?
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProviderConfiguration()
        transcription = (try? c.decodeIfPresent(TranscriptionService.self, forKey: .transcription)) ?? defaults.transcription
        notes = (try? c.decodeIfPresent(NotesService.self, forKey: .notes)) ?? defaults.notes
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? defaults.model
        compatibleURL = (try? c.decodeIfPresent(String.self, forKey: .compatibleURL)) ?? defaults.compatibleURL
        localURL = (try? c.decodeIfPresent(String.self, forKey: .localURL))
    }
    public var resolvedModel: String { model.isEmpty ? notes.defaultModel : model }
    public var resolvedLocalURL: String { localURL?.isEmpty == false ? localURL! : notes.defaultLocalURL }
    public var notesHost: String? {
        switch notes {
        case .apple: nil
        case .ollama, .lmstudio: nil
        case .anthropic: "api.anthropic.com"
        case .openai: "api.openai.com"
        case .gemini: "generativelanguage.googleapis.com"
        case .compatible: URL(string: compatibleURL)?.host?.lowercased()
        }
    }
    public var allowedHosts: Set<String> { Set([transcription.host, notesHost].compactMap { $0 }) }
    public var dataFlow: String {
        let audio = transcription == .apple ? "Audio is transcribed on this Mac." : "Audio goes to \(transcription.name)."
        let text = notes == .apple ? "Notes are written on this Mac." : notes.isLocalServer ? "Transcript and included side notes go to your local model server on this Mac." : "Transcript and included side notes go to \(notes == .compatible ? (notesHost ?? "your configured server") : notes.name)."
        return audio + " " + text
    }
    public var leavesMac: Bool { transcription != .apple || (notes != .apple && !notes.isLocalServer) }
    /// A short label for chips and status lines.
    public var privacyLabel: String { leavesMac ? "Uses \(destinations.joined(separator: " and "))" : "On this Mac" }
    public var destinations: [String] {
        var names: [String] = []
        if transcription != .apple { names.append(transcription.name) }
        if !notes.isOnDevice { names.append(notes == .compatible ? (notesHost ?? "your server") : notes.name) }
        return names
    }
}

public struct Preferences: Codable, Sendable, Equatable {
    public var autoRecord = false
    public var detectCalls = true
    public var deleteAudio = true
    public var copyConsent = false
    public var captureAllApps = false
    public var captureApps = ["us.zoom.xos", "com.microsoft.teams2", "com.google.Chrome", "com.apple.Safari", "com.apple.FaceTime", "com.tinyspeck.slackmacgap"]
    public var locale = Locale.current.identifier
    public var providers = ProviderConfiguration()
    public var onboardingCompleted = false
    public var recordingConsent = false
    public var encrypted = false
    public var calendarEnabled = false
    public var storageBookmark: Data?
    // 2.0
    /// Show elapsed time beside the menu bar icon while recording.
    public var menuBarTimer = true
    /// ⌃⌥⌘R starts and stops a recording from anywhere.
    public var globalShortcut = true
    /// Show Hush in the Dock and app switcher while one of its windows is open.
    public var showInDock = true
    /// Remind before calendar meetings.
    public var meetingReminders = true
    public init() {}

    /// Every field falls back to its default. A newer or damaged preferences file can
    /// never reset onboarding, providers or storage just because one key changed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        autoRecord = value(.autoRecord, d.autoRecord)
        detectCalls = value(.detectCalls, d.detectCalls)
        deleteAudio = value(.deleteAudio, d.deleteAudio)
        copyConsent = value(.copyConsent, d.copyConsent)
        captureAllApps = value(.captureAllApps, d.captureAllApps)
        captureApps = value(.captureApps, d.captureApps)
        locale = value(.locale, d.locale)
        providers = value(.providers, d.providers)
        onboardingCompleted = value(.onboardingCompleted, d.onboardingCompleted)
        recordingConsent = value(.recordingConsent, d.recordingConsent)
        encrypted = value(.encrypted, d.encrypted)
        calendarEnabled = value(.calendarEnabled, d.calendarEnabled)
        storageBookmark = (try? c.decodeIfPresent(Data.self, forKey: .storageBookmark))
        menuBarTimer = value(.menuBarTimer, d.menuBarTimer)
        globalShortcut = value(.globalShortcut, d.globalShortcut)
        showInDock = value(.showInDock, d.showInDock)
        meetingReminders = value(.meetingReminders, d.meetingReminders)
    }
    public static func load(defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: "hush.preferences"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    public func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "hush.preferences") }
    }
}

public enum HushError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
