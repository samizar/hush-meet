import Foundation
import CryptoKit
import CSQLite
import MuesliCore

public actor MeetingStore {
    public let root: URL
    private var key: SymmetricKey?
    private let suppliedKey: SymmetricKey?
    private var connection: SQLiteConnection?
    private var database: OpaquePointer? { connection?.pointer }
    private static let marker = Data("HUSH1".utf8)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
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
    public func list() throws -> [Meeting] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var result: [Meeting] = []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("meeting.json")
            do { result.append(try decoder.decode(Meeting.self, from: read(url))) }
            catch { throw HushError.message("Couldn't read a saved meeting. The store may be locked or damaged. Your files have been kept.") }
        }
        for meeting in result { try index(meeting) }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
    public func save(_ meeting: Meeting, transcript: Transcript? = nil, markdown: String? = nil) throws {
        let dir = folder(meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write(encoder.encode(meeting), to: dir.appendingPathComponent("meeting.json"))
        if let transcript { try write(transcript.jsonData(), to: dir.appendingPathComponent("transcript.json")) }
        if let markdown { try write(Data(markdown.utf8), to: dir.appendingPathComponent("notes.md")) }
        try index(meeting)
    }
    public func transcript(_ id: UUID) throws -> Transcript {
        try Transcript.load(jsonData: read(folder(id).appendingPathComponent("transcript.json")))
    }
    /// Patch only annotations so an autosave cannot overwrite newer processing state or generated notes.
    public func saveSideNotes(_ id: UUID, text: String, includeInContext: Bool) throws {
        let url = folder(id).appendingPathComponent("meeting.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
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
        try FileManager.default.removeItem(at: folder(id))
        try execute("DELETE FROM meetings WHERE id = ?", values: [id.uuidString])
    }
    public func deleteAll() throws {
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: url.lastPathComponent) != nil {
            try FileManager.default.removeItem(at: url)
        }
        try execute("DELETE FROM meetings", values: [])
    }
    public func size() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return e.compactMap { $0 as? URL }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    public func search(_ query: String) throws -> Set<UUID> {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        guard !words.isEmpty else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id FROM meetings WHERE meetings MATCH ? ORDER BY rank", -1, &statement, nil) == SQLITE_OK else { throw HushError.message("Search couldn't run.") }
        defer { sqlite3_finalize(statement) }
        bind(words.joined(separator: " AND "), to: statement, at: 1)
        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: raw)) { ids.insert(id) }
        }
        return ids
    }
    private func index(_ meeting: Meeting) throws {
        try execute("DELETE FROM meetings WHERE id = ?", values: [meeting.id.uuidString])
        let notes = (try? markdown(meeting.id)) ?? ""
        let text = (try? transcript(meeting.id).plainText()) ?? ""
        try execute("INSERT INTO meetings(id, title, content) VALUES (?, ?, ?)", values: [meeting.id.uuidString, meeting.title, notes + "\n" + meeting.userNotes + "\n" + text])
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
        try output.write(to: url, options: [.atomic, .completeFileProtection])
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

private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) { self.pointer = pointer }
    deinit { sqlite3_close(pointer) }
}
