import Foundation
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
    public init(id: UUID = UUID(), title: String = "Untitled meeting", startedAt: Date = .now,
                locale: String = Locale.current.identifier, templateID: String = "quick") {
        self.id = id; self.title = title; self.startedAt = startedAt; self.locale = locale
        self.templateID = templateID; userNotes = ""; state = .recording; transcriptionFinal = false
    }
    public var duration: TimeInterval { max(0, (endedAt ?? .now).timeIntervalSince(startedAt)) }
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
    case apple, anthropic, openai, gemini, compatible
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .apple: "Apple on-device"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        case .compatible: "OpenAI-compatible"
        }
    }
    public var defaultModel: String {
        switch self {
        case .apple: ""
        case .anthropic: "claude-sonnet-4-6"
        case .openai: "gpt-4.1-mini"
        case .gemini: "gemini-3.8-flash"
        case .compatible: ""
        }
    }
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var transcription: TranscriptionService = .apple
    public var notes: NotesService = .apple
    public var model: String = ""
    public var compatibleURL: String = "https://localhost:11434/v1"
    public init() {}
    public var resolvedModel: String { model.isEmpty ? notes.defaultModel : model }
    public var notesHost: String? {
        switch notes {
        case .apple: nil
        case .anthropic: "api.anthropic.com"
        case .openai: "api.openai.com"
        case .gemini: "generativelanguage.googleapis.com"
        case .compatible: URL(string: compatibleURL)?.host?.lowercased()
        }
    }
    public var allowedHosts: Set<String> { Set([transcription.host, notesHost].compactMap { $0 }) }
    public var dataFlow: String {
        let audio = transcription == .apple ? "Audio is transcribed on this Mac." : "Audio goes to \(transcription.name)."
        let text = notes == .apple ? "Notes are written on this Mac." : "Transcript text goes to \(notes == .compatible ? (notesHost ?? "your configured server") : notes.name)."
        return audio + " " + text
    }
    public var leavesMac: Bool { transcription != .apple || notes != .apple }
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
    public init() {}
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
