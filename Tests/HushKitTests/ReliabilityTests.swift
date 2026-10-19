import Foundation
import Testing
import CryptoKit
@testable import HushKit
import MuesliCore

@Suite("2.0 reliability")
struct ReliabilityTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hush-test-" + UUID().uuidString, isDirectory: true) }

    @Test func preferencesSurviveMissingAndUnknownValues() throws {
        // An older file without 2.0 keys, plus a provider this version doesn't know.
        let json = #"{"onboardingCompleted": true, "calendarEnabled": true, "locale": "fi-FI", "providers": {"notes": "futureProvider", "model": "x"}}"#
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(preferences.onboardingCompleted && preferences.calendarEnabled && preferences.locale == "fi-FI")
        #expect(preferences.providers.notes == .apple && preferences.providers.model == "x")
        #expect(preferences.globalShortcut && preferences.menuBarTimer && preferences.showInDock && preferences.meetingReminders)
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)) == Preferences())
    }

    @Test func meetingDecodesWithMissingOptionalFields() throws {
        let id = UUID()
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(#"{"id": "\#(id.uuidString)", "title": "Old", "state": "somethingNew"}"#.utf8))
        #expect(meeting.id == id && meeting.title == "Old" && meeting.state == .failed && meeting.userNotes.isEmpty)
        #expect(meeting.attendees == nil && meeting.notesEdited == nil)
    }

    @Test func oneDamagedMeetingDoesNotHideTheRest() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let good = Meeting(title: "Readable"); try await store.save(good)
        let bad = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("meeting.json"))
        let empty = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let listed = try await store.list()
        #expect(listed.map(\.id) == [good.id])
        #expect(await store.damaged.map(\.lastPathComponent) == [bad.lastPathComponent])
    }

    @Test func onlyDamagedMeetingsIsAnError() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let bad = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: bad.appendingPathComponent("meeting.json"))
        await #expect(throws: HushError.self) { try await store.list() }
    }

    @Test func lateSaveCannotRecreateDeletedMeeting() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Gone"); try await store.save(meeting)
        try await store.delete(meeting.id)
        try await store.save(meeting, markdown: "late")
        #expect(!FileManager.default.fileExists(atPath: await store.folder(meeting.id).path))
    }

    @Test func searchReturnsHighlightedSnippetsAndTasks() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Budget review"); meeting.state = .ready
        try await store.save(meeting, markdown: "# Budget review\n\nWe discussed the marmalade budget.\n\n- [ ] Send figures — Sam · 2026-10-21\n- [x] Book room")
        let hits = try await store.searchHits("marmalade")
        #expect(hits.count == 1)
        #expect(hits[0].snippet.contains(SearchHit.open + "marmalade" + SearchHit.close))
        let tasks = await store.tasks()
        #expect(tasks.map(\.text) == ["Send figures — Sam · 2026-10-21", "Book room"])
        #expect(tasks.map(\.done) == [false, true])
    }

    @Test func checklistToggleChangesOnlyThatLine() {
        let notes = "## Action items\n- [ ] First\n  * [x] Nested\nPlain - [ ] text"
        let toggled = NotesMarkdown.toggling(notes, line: 1)
        #expect(toggled == "## Action items\n- [x] First\n  * [x] Nested\nPlain - [ ] text")
        #expect(NotesMarkdown.toggling(notes, line: 2) == "## Action items\n- [ ] First\n  * [ ] Nested\nPlain - [ ] text")
        #expect(NotesMarkdown.toggling(notes, line: 3) == nil)
        #expect(NotesMarkdown.toggling(notes, line: 1, expecting: "Different") == nil)
    }

    @Test func interruptedWaveHeaderIsRepaired() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("me.wav")
        var bytes = WaveAudio.encode(samples: Data(repeating: 7, count: 32_000))
        // A writer that never finished leaves zero sizes in the header.
        bytes.replaceSubrange(4..<8, with: [0, 0, 0, 0]); bytes.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        try bytes.write(to: url)
        #expect(try WaveRepair.repair(fileAt: url))
        let fixed = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 { fixed[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }
        #expect(u32(4) == UInt32(fixed.count - 8)); #expect(u32(40) == 32_000)
        #expect(try WaveRepair.repair(fileAt: url) == false)
    }

    @Test func templatesCanBeCreatedEditedRestoredAndRemoved() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var templates = try Templates.load(directory: root)
        #expect(templates.count == Templates.builtIns.count)
        var quick = try #require(templates.first { $0.id == "quick" })
        quick.instruction = "Only decisions."
        try Templates.save(quick)
        templates = try Templates.load(directory: root)
        let edited = try #require(templates.first { $0.id == "quick" })
        #expect(edited.instruction == "Only decisions." && edited.isModified && edited.isBuiltIn)
        #expect(throws: HushError.self) { try Templates.remove(edited) }
        #expect(try Templates.restore(edited).isModified == false)
        let custom = try Templates.create(named: "Standup", directory: root)
        #expect(!custom.isBuiltIn && custom.name == "Standup" && custom.layout.contains("{{action_items}}"))
        try Templates.remove(custom)
        #expect(try Templates.load(directory: root).count == Templates.builtIns.count)
        var empty = custom; empty.name = "  "
        #expect(throws: HushError.self) { try Templates.save(empty) }
    }

    @Test func pacedGeneratorBoundsEachRequestAndCounts() async throws {
        struct Slow: NotesGenerator {
            var displayName: String { "slow" }
            var transcriptCharacterBudget: Int { get async { 4_000 } }
            func generate(system: String, user: String) async throws -> GenerationResult {
                try await Task.sleep(for: .seconds(5)); return GenerationResult(notes: GeneratedNotes())
            }
        }
        let counts = Counts()
        let paced = PacedNotesGenerator(base: Slow(), perRequest: .milliseconds(50)) { counts.add($0) }
        await #expect(throws: HushError.self) { _ = try await paced.generate(system: "", user: "") }
        #expect(counts.values == [1])
    }

    @Test func attendeesReachThePromptEscaped() {
        let context = MeetingContext(title: "Sync", start: Date(timeIntervalSince1970: 1_700_000_000), attendees: ["Ana <ops>", "Ben"])
        let prompt = Prompts.single(transcript: "[00:01] Me: hi", context: context)
        #expect(prompt.contains("Invited (from the calendar, may not all have attended): Ana &lt;ops&gt;, Ben"))
        #expect(!Prompts.single(transcript: "x", context: MeetingContext(start: .now)).contains("Invited"))
    }

    @Test func plannedPartsMatchesSummarizerChunking() {
        let segments = (0..<200).map { TranscriptSegment(speaker: $0.isMultiple(of: 2) ? .me : .them, start: Double($0) * 10, end: Double($0) * 10 + 5, text: String(repeating: "word ", count: 40)) }
        let transcript = Transcript(locale: "en-US", segments: segments)
        let context = MeetingContext(start: .now)
        #expect(MeetingSummarizer.plannedParts(Transcript(locale: "en-US", segments: Array(segments.prefix(2))), context: context, modelBudget: 3_600) == 1)
        #expect(MeetingSummarizer.plannedParts(transcript, context: context, modelBudget: 3_600) > 10)
    }

    @Test func anthropicFallbackOnlyForSupportedModels() {
        #expect(CloudNotesProvider.supportsServerFallback("claude-opus-5-5"))
        #expect(!CloudNotesProvider.supportsServerFallback("claude-haiku-5-5"))
        #expect(NotesService.anthropic.defaultModel == "claude-opus-5-5")
    }
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func add(_ value: Int) { lock.withLock { stored.append(value) } }
    var values: [Int] { lock.withLock { stored } }
}
