import Foundation
import Testing
import HushKit
import MuesliAudio
import MuesliCore
import MuesliTranscribe

@Suite("Apple Speech integration")
struct SpeechIntegrationTests {
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
