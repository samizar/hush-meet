import Foundation
import MuesliCore
import os

/// Only fixed events and numerical metadata are accepted: no titles, transcript, audio, URLs or keys.
public final class DiagnosticLog: Sendable {
    public enum Event: String, Sendable {
        case captureStarted, stopRequested, audioDrained, speechFinished, speechTimedOut
        case processingFailed, processingCancelled, retryStarted, notesStarted, notesFinished
        case modelCheckStarted, modelCheckFinished, modelCheckFailed
        case microphoneChanged, microphoneInterrupted, stoppedForSleep, audioRepaired
        case recoveryQueued, storeDamaged, lowDiskSpace, notesRequest
    }
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hush/Diagnostics", isDirectory: true)
    public static let shared = DiagnosticLog(directory: directory)
    private let directoryURL: URL
    private let byteLimit: Int
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private let logger = Logger(subsystem: "app.hush.mac", category: "pipeline")
    public init(directory: URL, byteLimit: Int = 128 * 1024) { directoryURL = directory; self.byteLimit = byteLimit }

    public func record(_ event: Event, count: Int? = nil, error: Error? = nil) {
        let code = error.map { ($0 as NSError).code }
        let line = Self.line(event, count: count, errorCode: code)
        logger.notice("\(line, privacy: .public)")
        lock.withLock { _ in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directoryURL.appendingPathComponent("pipeline.log")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= byteLimit {
                    let previous = directoryURL.appendingPathComponent("pipeline.previous.log")
                    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                    try fm.moveItem(at: url, to: previous)
                }
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: Data((line + "\n").utf8))
            } catch { /* Diagnostics must never interrupt recording or processing. */ }
        }
    }
    static func line(_ event: Event, count: Int?, errorCode: Int?) -> String {
        Date.now.ISO8601Format() + " event=" + event.rawValue
            + (count.map { " count=\($0)" } ?? "") + (errorCode.map { " errorCode=\($0)" } ?? "")
    }
}
