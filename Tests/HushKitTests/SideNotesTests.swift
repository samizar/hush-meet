import Foundation
import CryptoKit
import Testing
import HushKit
import MuesliCore

@Suite("Side notes persistence")
struct SideNotesTests {
    @Test func oldMeetingsAndPreferencesDecodeWithoutNewFields() throws {
        var meeting = Meeting(); meeting.userNotes = "Existing outline"
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(meeting)) as! [String: Any]
        object.removeValue(forKey: "useSideNotesAsContext"); object.removeValue(forKey: "notesContextDigest")
        let decoded = try decoder.decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.includesSideNotes); #expect(decoded.summaryContext.userNotes == "Existing outline")
        var preferences = try JSONSerialization.jsonObject(with: encoder.encode(Preferences())) as! [String: Any]
        var providers = preferences["providers"] as! [String: Any]; providers.removeValue(forKey: "localURL"); preferences["providers"] = providers
        #expect(try decoder.decode(Preferences.self, from: JSONSerialization.data(withJSONObject: preferences)).providers.notes == .apple)
    }
    @Test func optOutExcludesSideNotesAndDetectsChangedContext() {
        var meeting = Meeting(); meeting.userNotes = "Private brainstorming"
        meeting.structuredNotes = MeetingNotes(normalizing: GeneratedNotes(summary: "Earlier summary"), context: meeting.summaryContext, generatedBy: "test")
        meeting.notesContextDigest = meeting.contextDigest
        #expect(!meeting.sideNotesChanged)
        meeting.useSideNotesAsContext = false
        #expect(meeting.summaryContext.userNotes == nil); #expect(meeting.sideNotesChanged)
        meeting.notesContextDigest = meeting.contextDigest
        meeting.userNotes = "A different private thought"
        #expect(!meeting.sideNotesChanged) // Excluded edits do not stale an AI summary.
    }
    @Test func encryptedAutosavePreservesNewerGeneratedNotesAndSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = try MeetingStore(root: root, encrypted: true, encryptionKey: key)
        var meeting = Meeting(title: "Latest title", startedAt: Date(timeIntervalSince1970: 1_700_000_000)); meeting.state = .ready; meeting.transcriptionFinal = true
        meeting.structuredNotes = MeetingNotes(normalizing: GeneratedNotes(summary: "Keep this generated summary"), context: meeting.summaryContext, generatedBy: "test")
        try await store.save(meeting, markdown: "Latest AI output")
        try await store.saveSideNotes(meeting.id, text: "Confidential papaya agenda", includeInContext: false)
        let saved = try #require(try await store.list().first)
        #expect(saved.title == meeting.title && saved.state == .ready && saved.transcriptionFinal)
        #expect(saved.structuredNotes == meeting.structuredNotes)
        #expect(saved.userNotes == "Confidential papaya agenda" && !saved.includesSideNotes)
        #expect(try await store.markdown(meeting.id) == "Latest AI output")
        #expect(try await store.search("papaya") == [meeting.id])
        let bytes = try Data(contentsOf: await store.folder(meeting.id).appendingPathComponent("meeting.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("papaya"))
        let reopened = try MeetingStore(root: root, encrypted: true, encryptionKey: key)
        #expect(try await reopened.list().first?.userNotes == saved.userNotes)
    }
    @Test func pendingSaveCannotResurrectDeletedMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(); try await store.save(meeting); try await store.delete(meeting.id)
        try await store.saveSideNotes(meeting.id, text: "Late edit", includeInContext: true)
        #expect(try await store.list().isEmpty)
    }
}
