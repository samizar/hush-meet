import AVFAudio
import CoreMedia
import Foundation
import MuesliAudio
import MuesliCore
import os
import Speech

/// Turns one stream of audio (mic *or* system) into timestamped segments using
/// Apple's on-device `SpeechAnalyzer`. Run one per stream and merge the output
/// into a `Transcript`.
@available(macOS 26.0, *)
public struct StreamTranscriber: Sendable {
    public enum TranscribeError: Error, LocalizedError {
        case unavailable
        case unsupportedLocale(String)
        case noAudioFormat
        case conversion(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: "On-device speech transcription isn't available on this Mac."
            case .unsupportedLocale(let id): "Speech recognition doesn't support the locale “\(id)”."
            case .noAudioFormat: "The speech model didn't report a usable audio format."
            case .conversion(let why): "Audio format conversion failed: \(why)"
            }
        }
    }

    public let speaker: Speaker
    public let locale: Locale
    /// Host time (see `HostClock`) that all segment timestamps are relative to,
    /// so mic and system segments line up. `nil` → this stream's own start.
    public let sessionStart: UInt64?

    public init(speaker: Speaker, locale: Locale, sessionStart: UInt64? = nil) {
        self.speaker = speaker
        self.locale = locale
        self.sessionStart = sessionStart
    }

    // MARK: - Model management

    /// Maps the requested locale to one the recognizer supports and makes sure
    /// its on-device model is installed (downloading it if needed).
    public static func prepare(locale: Locale, onDownload: @Sendable (Progress) -> Void = { _ in }) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TranscribeError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.unsupportedLocale(locale.identifier)
        }
        let probe = makeTranscriber(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onDownload(request.progress)
            try await request.downloadAndInstall()
        }
        return supported
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    // MARK: - Transcription

    /// Consumes `chunks` until the stream ends, yielding finalized segments as
    /// the recognizer produces them. The returned stream finishes after the
    /// last segment has been flushed.
    public func transcribe(_ chunks: AsyncStream<AudioChunk>, onUpdate: @escaping @Sendable (TranscriptSegment, Bool) -> Void = { _, _ in }) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(chunks, into: continuation, onUpdate: onUpdate)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ chunks: AsyncStream<AudioChunk>, into out: AsyncThrowingStream<TranscriptSegment, Error>.Continuation, onUpdate: @escaping @Sendable (TranscriptSegment, Bool) -> Void) async throws {
        // A selected call app may produce no buffers at all. Do not start a recognizer
        // for that channel: finishing an analyzer with no consumed input can wait forever.
        var firstIterator = chunks.makeAsyncIterator()
        guard let first = await firstIterator.next() else { return }
        try Task.checkCancellation()
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError.noAudioFormat
        }
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let offset = sessionStart.map { first.hostTime == 0 ? 0 : HostClock.seconds(from: $0, to: first.hostTime) } ?? 0
        let speaker = self.speaker
        let log = Logger(subsystem: "app.hush.mac", category: "speech")
        log.info("speech_started channel=\(speaker.rawValue, privacy: .public)")
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let start = offset + result.range.start.seconds
                        let segment = TranscriptSegment(speaker: speaker, start: start,
                            end: max(offset + result.range.end.seconds, start), text: text,
                            confidence: Self.meanConfidence(result.text))
                        onUpdate(segment, result.isFinal)
                        if result.isFinal { out.yield(segment) }
                    }
                }
                group.addTask {
                    defer { inputContinuation.finish() }
                    var converter: PCMConverter?
                    func supply(_ chunk: AudioChunk) throws {
                        if converter == nil || converter?.inputFormat != chunk.buffer.format {
                            if let tail = try converter?.flush() { inputContinuation.yield(AnalyzerInput(buffer: tail)) }
                            converter = try PCMConverter(from: chunk.buffer.format, to: analyzerFormat)
                        }
                        if let buffer = try converter?.convert(chunk.buffer) { inputContinuation.yield(AnalyzerInput(buffer: buffer)) }
                    }
                    try supply(first)
                    // Only one iterator consumes chunks at a time: the first read above is complete.
                    for await chunk in chunks { try Task.checkCancellation(); try supply(chunk) }
                    try Task.checkCancellation()
                    if let tail = try converter?.flush() { inputContinuation.yield(AnalyzerInput(buffer: tail)) }
                    log.info("speech_input_ended channel=\(speaker.rawValue, privacy: .public)")
                }
                group.addTask {
                    // Structured analysis supplies the actual final time, including the empty-input case.
                    let last = try await analyzer.analyzeSequence(inputs)
                    try Task.checkCancellation()
                    if let last {
                        try await AsyncDeadline.run(for: .seconds(15)) { try await analyzer.finalizeAndFinish(through: last) }
                    } else { await analyzer.cancelAndFinishNow() }
                    log.info("speech_finished channel=\(speaker.rawValue, privacy: .public)")
                }
                do { while try await group.next() != nil {} }
                catch {
                    group.cancelAll(); inputContinuation.finish()
                    Task { await analyzer.cancelAndFinishNow() }
                    log.error("speech_failed channel=\(speaker.rawValue, privacy: .public) code=\((error as NSError).code)")
                    throw error
                }
            }
        } onCancel: {
            inputContinuation.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func meanConfidence(_ text: AttributedString) -> Double? {
        var total = 0.0, count = 0
        for run in text.runs {
            if let c = run.transcriptionConfidence {
                total += c
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }
}
