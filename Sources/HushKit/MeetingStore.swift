import Foundation
import CryptoKit
import CSQLite
import MuesliCore

/// A search match with a short excerpt. Highlighted words sit between `SearchHit.open` and `SearchHit.close`.
public struct SearchHit: Sendable, Equatable {
    public static let open = "\u{1}"
    public static let close = "\u{2}"
    public var id: UUID
    public var snippet: String
    public init(id: UUID, snippet: String) { self.id = id; self.snippet = snippet }
}

/// A checklist line in a meeting's notes: `- [ ] Send the budget — Sam · Friday`.
public struct NoteTask: Identifiable, Sendable, Equatable, Hashable {
    public var meetingID: UUID
    public var line: Int
    public var text: String
    public var done: Bool
    public var id: String { meetingID.uuidString + ":" + String(line) }
    public init(meetingID: UUID, line: Int, text: String, done: Bool) {
        self.meetingID = meetingID; self.line = line; self.text = text; self.done = done
    }
}

public enum NotesMarkdown {
    /// Returns the task on a line, or nil. Accepts `-` or `*` bullets and `[x]`/`[X]`.
    public static func task(in line: String) -> (done: Bool, text: String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.count >= 6, ["-", "*"].contains(trimmed.first), trimmed.dropFirst().first == " " else { return nil }
        let rest = trimmed.dropFirst(2)
        guard rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") else { return nil }
        return (rest.dropFirst().first != " ", String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces))
    }
    public static func tasks(in markdown: String, meetingID: UUID) -> [NoteTask] {
        markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
            task(in: line).map { NoteTask(meetingID: meetingID, line: index, text: $0.text, done: $0.done) }
        }
    }
    /// Flips one checkbox. Returns nil when the line is no longer a task (the notes changed).
    public static func toggling(_ markdown: String, line index: Int, expecting text: String? = nil) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(index), let found = task(in: lines[index]) else { return nil }
        if let text, found.text != text { return nil }
        let line = lines[index]
        guard let open = line.firstIndex(of: "[") else { return nil }
        let mark = line.index(after: open)
        lines[index] = line.replacingCharacters(in: mark...mark, with: found.done ? " " : "x")
        return lines.joined(separator: "\n")
    }
}

public actor MeetingStore {
    public let root: URL
    private var key: SymmetricKey?
    private let suppliedKey: SymmetricKey?
    private var connection: SQLiteConnection?
    private var database: OpaquePointer? { connection?.pointer }
    private static let marker = Data("HUSH1".utf8)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Decrypted text kept for the in-memory search index, so autosaves never re-read transcripts.
    private var cache: [UUID: (notes: String, transcript: String)] = [:]
    /// Deleted meetings. A late autosave must never recreate their folders.
    private var tombstones = Set<UUID>()
    /// Folders that couldn't be read during the last `list()`.
    public private(set) var damaged: [URL] = []

    public init(root: URL? = nil, encrypted: Bool = false, encryptionKey: SymmetricKey? = nil) throws {
        self.root = root ?? Self.defaultRoot
        suppliedKey = encryptionKey
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if encrypted { key = try encryptionKey ?? Secrets.storeKey() }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        // In-memory FTS avoids leaving transcript fragments in SQLite journals or deleted pages.
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else { throw HushError.message("Couldn't open the local search index.") }
        guard sqlite3_exec(db, "CREATE VIRTUAL TABLE meetings USING fts5(id UNINDEXED, title, content, tokenize='unicode61 remove_diacritics 2')", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db); throw HushError.message("Couldn't create the local search index.")
        }
        connection = SQLiteConnection(db)
    }
    public static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hush", isDirectory: true)
    }
    public static var defaultRoot: URL { supportRoot.appendingPathComponent("Meetings", isDirectory: true) }
    public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    /// Reads every meeting. A damaged folder is skipped and reported in `damaged`, so one bad
    /// file never hides the rest. If nothing can be read at all, the store is locked or the
    /// key is wrong, and that is an error.
    public func list() throws -> [Meeting] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        var result: [Meeting] = []
        var unreadable: [URL] = []
        for folder in folders {
            Self.allowWritesWhileLocked(folder)
            let url = folder.appendingPathComponent("meeting.json")
            // A folder without meeting.json is an interrupted creation, not a damaged meeting.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { result.append(try decoder.decode(Meeting.self, from: read(url))) }
            catch { unreadable.append(folder) }
        }
        damaged = unreadable
        if result.isEmpty && !unreadable.isEmpty {
            throw HushError.message("Hush couldn't open your meetings. If they're encrypted, unlock your login keychain and reopen Hush. Your files have been kept.")
        }
        for meeting in result { try index(meeting) }
        return result.sorted { $0.startedAt > $1.startedAt }
    }

    /// Files written before 2.0.1 used complete protection, which blocks reading and replacing them
    /// while the screen is locked. Relax them to the class new files use. Failures are harmless.
    static func allowWritesWhileLocked(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
    }
    public func save(_ meeting: Meeting, transcript: Transcript? = nil, markdown: String? = nil) throws {
        guard !tombstones.contains(meeting.id) else { return }
        let dir = folder(meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(encoder.encode(meeting), to: dir.appendingPathComponent("meeting.json"))
        var entry = cache[meeting.id] ?? (try? loadEntry(meeting.id)) ?? ("", "")
        if let transcript { try write(transcript.jsonData(), to: dir.appendingPathComponent("transcript.json")); entry.transcript = transcript.plainText() }
        if let markdown { try write(Data(markdown.utf8), to: dir.appendingPathComponent("notes.md")); entry.notes = markdown }
        cache[meeting.id] = entry
        try index(meeting)
    }
    public func transcript(_ id: UUID) throws -> Transcript {
        try Transcript.load(jsonData: read(folder(id).appendingPathComponent("transcript.json")))
    }
    public func hasTranscript(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent("transcript.json").path)
    }
    /// Patch only annotations so an autosave cannot overwrite newer processing state or generated notes.
    public func saveSideNotes(_ id: UUID, text: String, includeInContext: Bool) throws {
        let url = folder(id).appendingPathComponent("meeting.json")
        guard !tombstones.contains(id), FileManager.default.fileExists(atPath: url.path) else { return }
        var meeting = try decoder.decode(Meeting.self, from: read(url))
        if meeting.notesContextDigest == nil, meeting.structuredNotes != nil { meeting.notesContextDigest = meeting.contextDigest }
        meeting.userNotes = text; meeting.useSideNotesAsContext = includeInContext
        try save(meeting)
    }
    public func markdown(_ id: UUID) throws -> String {
        String(decoding: try read(folder(id).appendingPathComponent("notes.md")), as: UTF8.self)
    }
    public func deleteAudio(_ id: UUID) throws {
        for name in ["me.wav", "them.wav", "me.wav.sealed", "them.wav.sealed"] {
            let url = folder(id).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    public func hasAudio(_ id: UUID) -> Bool {
        ["me.wav", "them.wav", "me.wav.sealed", "them.wav.sealed"].contains {
            ((try? folder(id).appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44
        }
    }
    /// Fixes WAV headers left incomplete when Hush quit unexpectedly during a recording.
    @discardableResult public func repairAudio(_ id: UUID) -> Int {
        ["me.wav", "them.wav"].reduce(0) { count, name in
            let url = folder(id).appendingPathComponent(name)
            return count + (((try? WaveRepair.repair(fileAt: url)) ?? false) ? 1 : 0)
        }
    }
    public func protectAudio(_ id: UUID) throws {
        for name in ["me.wav", "them.wav"] {
            let url = folder(id).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if key != nil {
                try write(Data(contentsOf: url), to: url.appendingPathExtension("sealed"))
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    /// A readable WAV for processing: the plain file (repaired if needed), or a private
    /// decrypted copy that the caller removes with `discardProcessingAudio`.
    public func processingAudio(_ id: UUID, name: String) throws -> URL? {
        guard ["me.wav", "them.wav"].contains(name) else { return nil }
        let dir = folder(id)
        let plain = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: plain.path) {
            if (try? WaveRepair.repair(fileAt: plain)) == true { DiagnosticLog.shared.record(.audioRepaired) }
            return ((try? plain.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44 ? plain : nil
        }
        let sealed = dir.appendingPathComponent(name + ".sealed")
        guard FileManager.default.fileExists(atPath: sealed.path) else { return nil }
        let bytes = try read(sealed)
        guard bytes.count > 44 else { return nil }
        let temporary = dir.appendingPathComponent(".processing-" + name)
        try bytes.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        return temporary
    }
    public func discardProcessingAudio(_ id: UUID) {
        for name in [".processing-me.wav", ".processing-them.wav", ".retry-me.wav", ".retry-them.wav"] {
            try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
        }
    }
    public func audioData(_ id: UUID, name: String) throws -> Data? {
        guard ["me.wav", "them.wav"].contains(name) else { return nil }
        let dir = folder(id)
        let sealed = dir.appendingPathComponent(name + ".sealed")
        let plain = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: sealed.path) { return try read(sealed) }
        if FileManager.default.fileExists(atPath: plain.path) { return try Data(contentsOf: plain) }
        return nil
    }
    public func delete(_ id: UUID) throws {
        tombstones.insert(id); cache[id] = nil
        let dir = folder(id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try execute("DELETE FROM meetings WHERE id = ?", values: [id.uuidString])
    }
    public func deleteAll() throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: url.lastPathComponent) != nil {
            if let id = UUID(uuidString: url.lastPathComponent) { tombstones.insert(id) }
            try FileManager.default.removeItem(at: url)
        }
        cache = [:]; damaged = []
        try execute("DELETE FROM meetings", values: [])
    }
    public func size() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { $0 as? URL }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    public func search(_ query: String) throws -> Set<UUID> { Set(try searchHits(query).map(\.id)) }

    /// Ranked matches with a short highlighted excerpt.
    public func searchHits(_ query: String, limit: Int = 200) throws -> [SearchHit] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        guard !words.isEmpty else { return [] }
        var statement: OpaquePointer?
        let sql = "SELECT id, snippet(meetings, 2, char(1), char(2), '…', 12) FROM meetings WHERE meetings MATCH ? ORDER BY rank LIMIT ?"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw HushError.message("Search couldn't run.") }
        defer { sqlite3_finalize(statement) }
        bind(words.joined(separator: " AND "), to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [SearchHit] = []
        var seen = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: raw)), seen.insert(id).inserted else { continue }
            let snippet = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            hits.append(SearchHit(id: id, snippet: Self.cleanSnippet(snippet)))
        }
        return hits
    }
    /// Every checklist line across meetings, from the cached notes.
    public func tasks() -> [NoteTask] {
        cache.flatMap { id, entry in NotesMarkdown.tasks(in: entry.notes, meetingID: id) }
    }

    static func cleanSnippet(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "- [ ] ", with: "").replacingOccurrences(of: "- [x] ", with: "")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "## ", with: "").replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
    private func loadEntry(_ id: UUID) throws -> (notes: String, transcript: String) {
        ((try? markdown(id)) ?? "", (try? transcript(id).plainText()) ?? "")
    }
    private func index(_ meeting: Meeting) throws {
        let entry = cache[meeting.id] ?? ((try? loadEntry(meeting.id)) ?? ("", ""))
        cache[meeting.id] = entry
        try execute("DELETE FROM meetings WHERE id = ?", values: [meeting.id.uuidString])
        let people = (meeting.attendees ?? []).joined(separator: " ")
        try execute("INSERT INTO meetings(id, title, content) VALUES (?, ?, ?)", values: [meeting.id.uuidString, meeting.title,
            entry.notes + "\n" + meeting.userNotes + "\n" + people + "\n" + entry.transcript])
    }
    private func execute(_ sql: String, values: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw HushError.message("Couldn't update the search index.") }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() { bind(value, to: statement, at: Int32(i + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw HushError.message("Couldn't update the search index.") }
    }
    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func read(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.starts(with: Self.marker) else { return data }
        let key = try self.key ?? suppliedKey ?? Secrets.storeKey()
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(Self.marker.count)), using: key)
    }
    private func write(_ data: Data, to url: URL) throws {
        let output: Data
        if let key {
            guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw HushError.message("Couldn't encrypt this meeting.") }
            output = Self.marker + sealed
        } else { output = data }
        // Protected until the first unlock after boot. Complete protection would refuse writes while the
        // screen is locked, so a recording or notes finishing on a locked Mac couldn't be saved.
        try output.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Rewrites into a protected staging directory before replacing any original files.
    public func setEncryption(_ enabled: Bool) throws {
        let newKey = enabled ? try suppliedKey ?? Secrets.storeKey() : nil
        let previousKey = key
        let stage = root.appendingPathComponent(".migration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        do {
            for folder in folders {
                let target = stage.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for source in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    let plain = try read(source)
                    key = newKey
                    var name = source.lastPathComponent.replacingOccurrences(of: ".sealed", with: "")
                    if enabled && name.hasSuffix(".wav") { name += ".sealed" }
                    try write(plain, to: target.appendingPathComponent(name))
                    key = previousKey
                }
            }
            // Each folder replacement is atomic. Readers recognize encrypted headers during recovery.
            for folder in folders {
                _ = try FileManager.default.replaceItemAt(folder, withItemAt: stage.appendingPathComponent(folder.lastPathComponent))
            }
            key = newKey
        } catch { key = previousKey; throw error }
    }
}

/// Repairs the RIFF and data sizes of a WAV whose writer never finished. Audio after the
/// header is kept as is; only the two length fields change.
public enum WaveRepair {
    @discardableResult public static func repair(fileAt url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 44, size < UInt64(UInt32.max) else { return false }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard let fix = plan(header: header, fileSize: Int(size)) else { return false }
        for (offset, value) in fix {
            try handle.seek(toOffset: UInt64(offset))
            var le = value.littleEndian
            try handle.write(contentsOf: Data(bytes: &le, count: 4))
        }
        return true
    }
    /// Field offsets and the values they should hold, or nil when the header is already right.
    static func plan(header: Data, fileSize: Int) -> [(Int, UInt32)]? {
        let bytes = [UInt8](header)
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = tag(offset), length = Int(u32(offset + 4))
            if id == "data" {
                let available = fileSize - (offset + 8)
                let expectedData = UInt32(available - available % 2)
                let expectedRIFF = UInt32(fileSize - 8)
                var changes: [(Int, UInt32)] = []
                if u32(offset + 4) != expectedData { changes.append((offset + 4, expectedData)) }
                if u32(4) != expectedRIFF { changes.append((4, expectedRIFF)) }
                return changes.isEmpty ? nil : changes
            }
            offset += 8 + length + (length % 2)
        }
        return nil
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}
