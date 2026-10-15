import Foundation
import AVFAudio
import Testing
@testable import HushKit
import MuesliAudio
import MuesliCore
import MuesliTranscribe

@Suite("Apple Speech integration", .serialized)
struct SpeechIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_SPEECH_TESTS"] == "1"))
    func emptyChannelFinishesWithoutWaitingForSpeech() async throws {
        let locale = try await StreamTranscriber.prepare(locale: Locale(identifier: "en-US"))
        let empty = AsyncStream<MuesliAudio.AudioChunk> { $0.finish() }
        var count = 0
        for try await _ in StreamTranscriber(speaker: .them, locale: locale).transcribe(empty) { count += 1 }
        #expect(count == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_SPEECH_TESTS"] == "1")) @MainActor
    func stopSavesSpokenMicrophoneAndEmptyOtherChannel() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["HUSH_SPEECH_FIXTURE"])
        let locale = try await StreamTranscriber.prepare(locale: Locale(identifier: "en-US"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = CaptureSession()
        try capture.consume([(.me, try AudioFileSource.chunks(url: URL(fileURLWithPath: fixture))),
                             (.them, AsyncStream { $0.finish() })], locale: locale, preferences: Preferences(), folder: folder)
        let transcript = try await capture.stop()
        #expect(!capture.isRecording)
        #expect(!transcript.segments.isEmpty)
        #expect(transcript.segments.allSatisfy { $0.speaker == .me })
        #expect(transcript.plainText().localizedCaseInsensitiveContains("meeting"))
        #expect(try AVAudioFile(forReading: folder.appendingPathComponent("me.wav")).length > 0)
        #expect(try AVAudioFile(forReading: folder.appendingPathComponent("them.wav")).length == 0)
        #expect(capture.volatileMe.isEmpty && capture.volatileThem.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_SPEECH_TESTS"] == "1"))
    func shortSilentChannelFinishes() async throws {
        let locale = try await StreamTranscriber.prepare(locale: Locale(identifier: "en-US"))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1_600)
        let stream = AsyncStream<AudioChunk> { $0.yield(AudioChunk(buffer: buffer)); $0.finish() }
        var count = 0
        for try await _ in StreamTranscriber(speaker: .me, locale: locale).transcribe(stream) { count += 1 }
        #expect(count == 0)
    }

    @Test func cancelBeforeFirstBufferReturnsPromptly() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        defer { continuation.finish() }
        let task = Task {
            for try await _ in StreamTranscriber(speaker: .them, locale: Locale(identifier: "en-US")).transcribe(stream) {}
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        try await AsyncDeadline.run(for: .seconds(1)) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HUSH_RUN_SPEECH_TESTS"] == "1"))
    func transcribesSyntheticFileOnBothChannels() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["HUSH_SPEECH_FIXTURE"])
        let locale = try await StreamTranscriber.prepare(locale: Locale(identifier: "en-US"))
        func run(_ speaker: Speaker) async throws -> [TranscriptSegment] {
            var segments: [TranscriptSegment] = []
            let stream = try AudioFileSource.chunks(url: URL(fileURLWithPath: fixture))
            for try await segment in StreamTranscriber(speaker: speaker, locale: locale).transcribe(stream) { segments.append(segment) }
            return segments
        }
        async let me = run(.me)
        async let them = run(.them)
        let (first, second) = try await (me, them)
        #expect(!first.isEmpty); #expect(!second.isEmpty)
        #expect(first.allSatisfy { $0.speaker == .me })
        #expect(second.allSatisfy { $0.speaker == .them })
        #expect(first.map(\.text).joined().localizedCaseInsensitiveContains("meeting"))
        #expect(second.map(\.text).joined().localizedCaseInsensitiveContains("meeting"))
    }
}
