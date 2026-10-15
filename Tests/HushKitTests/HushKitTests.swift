import Foundation
import Testing
import CryptoKit
import AVFoundation
@testable import HushKit
import MuesliCore

@Suite("Network boundary")
struct NetworkBoundaryTests {
    @Test func localDefaultsHaveNoHosts() {
        let configuration = ProviderConfiguration()
        #expect(configuration.allowedHosts.isEmpty)
        #expect(!configuration.leavesMac)
        #expect(throws: HushError.self) { try NetworkClient.validate(URL(string: "https://api.openai.com/v1/models")!, allowedHosts: configuration.allowedHosts) }
    }
    @Test(arguments: ["http://api.openai.com/v1", "https://evil.example/", "https://api.openai.com.evil.example/", "https://user:password@api.openai.com/v1", "file:///etc/hosts", "https://api.openai.com/v1#token", "https://openai.com/"])
    func blocksUnconfiguredOrUnsafeURLs(_ raw: String) {
        #expect(throws: HushError.self) { try NetworkClient.validate(URL(string: raw)!, allowedHosts: ["api.openai.com"]) }
    }
    @Test func exactConfiguredHostWorks() throws {
        try NetworkClient.validate(URL(string: "https://api.openai.com/v1/audio/transcriptions")!, allowedHosts: ["api.openai.com"])
    }
    @Test func selectionIsExplicitAndScoped() {
        var configuration = ProviderConfiguration(); configuration.notes = .anthropic
        #expect(configuration.allowedHosts == ["api.anthropic.com"])
        #expect(configuration.dataFlow.contains("Audio is transcribed on this Mac"))
        #expect(configuration.leavesMac)
        configuration.transcription = .deepgram
        #expect(configuration.allowedHosts == ["api.anthropic.com", "api.deepgram.com"])
        configuration.notes = .compatible; configuration.compatibleURL = "https://inference.example/v1"
        #expect(configuration.allowedHosts == ["inference.example", "api.deepgram.com"])
    }
    @Test func preferencesNeverContainKeys() throws {
        let preferences = Preferences()
        let data = try JSONEncoder().encode(preferences)
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("apikey")); #expect(!text.contains("secret")); #expect(!text.contains("bearer"))
    }
}

@Suite("Meeting store")
struct StoreTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hush-test-" + UUID().uuidString, isDirectory: true) }
    @Test func roundTripSearchAndDeletion() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Design review", startedAt: Date(timeIntervalSince1970: 1_700_000_000)); meeting.state = .ready; meeting.transcriptionFinal = true
        let transcript = Transcript(startedAt: Date(timeIntervalSince1970: 1_700_000_000), locale: "en-US", segments: [.init(speaker: .them, start: 1, end: 3, text: "A remarkable zebra crossed the roadmap.")])
        try await store.save(meeting, transcript: transcript, markdown: "# Design review\n\nSend the budget on Friday.")
        #expect(try await store.list() == [meeting])
        #expect(try await store.transcript(meeting.id) == transcript)
        #expect(try await store.search("zebra") == [meeting.id])
        #expect(try await store.search("budg") == [meeting.id])
        #expect(try await store.search("design review") == [meeting.id])
        #expect(try await store.search("\" OR *") == [])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!files.contains { $0.contains("sqlite") })
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let folder = await store.folder(meeting.id)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("transcript.json").path)[.posixPermissions] as? NSNumber
        #expect(filePermissions?.intValue == 0o600)
        try await store.delete(meeting.id)
        #expect(try await store.list().isEmpty)
        #expect(try await store.search("zebra").isEmpty)
    }
    @Test func encryptedFilesDoNotContainMeetingText() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = try MeetingStore(root: root, encrypted: true, encryptionKey: key)
        let meeting = Meeting(title: "Sensitive kumquat discussion", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting, transcript: Transcript(locale: "en-US"), markdown: "Private kumquat notes")
        let folder = await store.folder(meeting.id)
        for name in ["meeting.json", "transcript.json", "notes.md"] {
            let bytes = try Data(contentsOf: folder.appendingPathComponent(name))
            #expect(bytes.starts(with: Data("HUSH1".utf8)))
            #expect(!String(decoding: bytes, as: UTF8.self).contains("kumquat"))
        }
        #expect(try await store.markdown(meeting.id) == "Private kumquat notes")
        #expect(try await store.search("kumquat") == [meeting.id])
        let reopened = try MeetingStore(root: root, encrypted: true, encryptionKey: key)
        #expect(try await reopened.list() == [meeting])
        let url = folder.appendingPathComponent("notes.md")
        var bytes = try Data(contentsOf: url); bytes[bytes.count - 1] ^= 1; try bytes.write(to: url)
        await #expect(throws: (any Error).self) { try await reopened.markdown(meeting.id) }
    }
    @Test func deletesAudioOnlyAndRebuildsIndex() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Persistence")
        try await store.save(meeting, markdown: "A rebuildable notebook.")
        let folder = await store.folder(meeting.id)
        for name in ["me.wav", "them.wav"] { try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name)) }
        try await store.deleteAudio(meeting.id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("me.wav").path))
        #expect(try await store.markdown(meeting.id) == "A rebuildable notebook.")
        let reopened = try MeetingStore(root: root); _ = try await reopened.list()
        #expect(try await reopened.search("rebuildable") == [meeting.id])
        try await reopened.deleteAll(); #expect(try await reopened.list().isEmpty)
    }
    @Test func encryptionMigrationPreservesFoldersAndAudio() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root, encryptionKey: SymmetricKey(size: .bits256))
        let meeting = Meeting(title: "Migration", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(meeting, transcript: Transcript(locale: "en-US"), markdown: "Preserve every word.")
        let folder = await store.folder(meeting.id)
        let audio = WaveAudio.encode(samples: Data(repeating: 0, count: 32000))
        try audio.write(to: folder.appendingPathComponent("me.wav"))
        try await store.setEncryption(true)
        #expect(try await store.list() == [meeting])
        #expect(try await store.markdown(meeting.id) == "Preserve every word.")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("me.wav").path))
        #expect(try await store.audioData(meeting.id, name: "me.wav") == audio)
        try await store.setEncryption(false)
        #expect(try await store.list() == [meeting])
        #expect(try await store.audioData(meeting.id, name: "me.wav") == audio)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("me.wav").path))
        #expect(!Data((try await store.markdown(meeting.id)).utf8).starts(with: Data("HUSH1".utf8)))
    }
}

@Suite("Calendar and templates")
struct CalendarAndTemplateTests {
    @Test func meetingRules() {
        #expect(CalendarService.isMeeting(allDay: false, declined: false, attendeeCount: 1, hasVideoLink: false))
        #expect(CalendarService.isMeeting(allDay: false, declined: false, attendeeCount: 0, hasVideoLink: true))
        #expect(!CalendarService.isMeeting(allDay: true, declined: false, attendeeCount: 1, hasVideoLink: true))
        #expect(!CalendarService.isMeeting(allDay: false, declined: true, attendeeCount: 1, hasVideoLink: true))
        #expect(!CalendarService.isMeeting(allDay: false, declined: false, attendeeCount: 0, hasVideoLink: false))
    }
    @Test func videoLinksRequireRealProviderHosts() {
        #expect(CalendarService.videoURL(in: "Join https://meet.google.com/abc-defg-hij")?.host == "meet.google.com")
        #expect(CalendarService.videoURL(in: "https://eu01.zoom.us/j/123") != nil)
        #expect(CalendarService.videoURL(in: "https://zoom.us.evil.example/j/123") == nil)
    }
    @Test func sixEditableTemplatesShareSchema() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hush-templates-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let templates = try Templates.load(directory: folder)
        #expect(templates.count == 6); #expect(templates.first?.id == "quick")
        let notes = MeetingNotes(normalizing: GeneratedNotes(title: "Review", summary: "We agreed to ship.", decisions: ["Ship Friday"], actionItems: [.init(title: "Send plan", owner: "Me")]), context: .init(start: .now), generatedBy: "test")
        for template in templates {
            let rendered = template.render(notes)
            #expect(rendered.contains("Send plan — Me")); #expect(!rendered.contains("{{"))
        }
        let custom = templates[0].url
        try "# My version\nKeep it brief.\n---\n{{summary}}".write(to: custom, atomically: true, encoding: .utf8)
        #expect(try Templates.load(directory: folder)[0].name == "My version")
        let copy = try Templates.duplicate(templates[1]); #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try Templates.load(directory: folder).count == 7)
    }
    @Test func waveEncodingProducesValidBoundedAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WaveAudio.encode(samples: Data(repeating: 0, count: 32000 * 3)).write(to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 48000)
        var count = 0
        for try await (data, start, duration) in try WaveAudio.chunks(file: url, seconds: 1) {
            #expect(data.count == 32044); #expect(start == Double(count)); #expect(duration == 1); count += 1
        }
        #expect(count == 3)
    }
}
