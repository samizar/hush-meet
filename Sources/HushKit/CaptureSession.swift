import Foundation
import Observation
import AVFoundation
import MuesliAudio
import MuesliCore
import MuesliTranscribe
import os

private final class ProgressBox: Sendable {
    private let value = OSAllocatedUnfairLock<Progress?>(initialState: nil)
    var progress: Progress? { value.withLock { $0 } }
    func set(_ progress: Progress) { value.withLock { $0 = progress } }
}

@MainActor @Observable
public final class CaptureSession {
    public private(set) var isRecording = false
    public private(set) var isPreparing = false
    public private(set) var progressText = ""
    public private(set) var meLevels: [Double] = Array(repeating: 0, count: 96)
    public private(set) var themLevels: [Double] = Array(repeating: 0, count: 96)
    public private(set) var volatileMe = ""
    public private(set) var volatileThem = ""
    public private(set) var transcript: Transcript?
    public private(set) var startedAt: Date?
    public private(set) var warning: String? { didSet { if warning == nil { settingsLink = nil } } }
    /// Where the person can fix the current warning, if anywhere.
    public private(set) var settingsLink: URL?
    /// The microphone in use, for the recording header.
    public private(set) var inputName: String?
    public static let systemAudioSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    public static let soundSettings = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
    @ObservationIgnored private var mic: MicrophoneCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var audioTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var recorders: [Speaker: StreamRecorder] = [:]
    @ObservationIgnored private var sessionEpoch: UInt64 = 0
    @ObservationIgnored private var generation = UUID()
    public var audioOffsets: [String: TimeInterval] {
        Dictionary(uniqueKeysWithValues: recorders.compactMap { speaker, recorder in
            recorder.firstHostTime.map { (speaker.rawValue, max(0, HostClock.seconds(from: sessionEpoch, to: $0))) }
        })
    }
    @ObservationIgnored private var lastMeMeter = Date.distantPast
    @ObservationIgnored private var lastThemMeter = Date.distantPast
    @ObservationIgnored private var lastHeardThem = Date.now
    @ObservationIgnored private var callPresent = false
    public init() {}
    public func start(meeting: Meeting, preferences: Preferences, folder: URL) async throws {
        guard !isRecording && !isPreparing else { return }
        isPreparing = true; warning = nil; progressText = "Getting ready…"; failures = []; recorders = [:]
        let generation = UUID(); self.generation = generation
        var downloadTask: Task<Void, Never>?
        defer { downloadTask?.cancel(); isPreparing = false; progressText = "" }
        let locale: Locale
        if preferences.providers.transcription == .apple {
            let download = ProgressBox()
            downloadTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let progress = download.progress {
                        self?.progressText = "Downloading Apple's speech model… \(Int(progress.fractionCompleted * 100))%"
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            locale = try await StreamTranscriber.prepare(locale: Locale(identifier: meeting.locale)) { progress in download.set(progress) }
        } else {
            guard let key = try Secrets.get(preferences.providers.transcription.rawValue), !key.isEmpty else {
                throw HushError.message("Add your \(preferences.providers.transcription.name) key in Settings → Models.")
            }
            locale = Locale(identifier: meeting.locale)
        }
        transcript = Transcript(startedAt: .now, locale: locale.identifier)
        let mic = MicrophoneCapture()
        mic.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch event {
                case .resumed(let device):
                    self.inputName = device
                    self.warning = nil
                    DiagnosticLog.shared.record(.microphoneChanged)
                case .interrupted:
                    self.warning = "Your microphone disconnected. Hush will continue as soon as one is available."
                    self.settingsLink = Self.soundSettings
                    DiagnosticLog.shared.record(.microphoneInterrupted)
                }
            }
        }
        inputName = MicrophoneCapture.currentInputName
        let system = SystemAudioCapture(scope: preferences.captureAllApps ? .everything : .only(AppSelector(preferences.captureApps)))
        system.onUpdate = { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch update {
                case .failed:
                    self.warning = "System audio stopped. Check System Settings → Privacy & Security → Screen & System Audio Recording."
                    self.settingsLink = Self.systemAudioSettings
                case .waiting: self.warning = "Waiting for a selected call app."
                case .following: self.warning = nil
                }
            }
        }
        do {
            let micStream = try await mic.start()
            let systemStream = try system.start()
            self.mic = mic; self.system = system
            try consume([(Speaker.me, micStream), (.them, systemStream)], locale: locale, preferences: preferences, folder: folder)
        } catch {
            mic.stop(); system.stop()
            for task in audioTasks { await task.value }
            for task in tasks { task.cancel() }
            self.generation = UUID()
            self.mic = nil; self.system = nil; tasks = []; audioTasks = []
            throw error
        }
    }
    /// Shared recording/transcription pipeline for live capture and synthetic-file regression tests.
    func consume(_ sources: [(Speaker, AsyncStream<AudioChunk>)], locale: Locale, preferences: Preferences, folder: URL) throws {
        let generation = self.generation
        let epoch = HostClock.now()
        sessionEpoch = epoch
        startedAt = .now; transcript = Transcript(startedAt: startedAt!, locale: locale.identifier); lastHeardThem = .now
        meLevels = Array(repeating: 0, count: 96); themLevels = meLevels
        for (speaker, source) in sources {
            let recorder = try StreamRecorder(url: folder.appendingPathComponent(speaker.rawValue + ".wav"))
            recorders[speaker] = recorder
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.url.path)
            let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
            audioTasks.append(Task.detached { [weak self] in
                var lastMeter: UInt64 = 0
                for await chunk in source {
                    do { try recorder.write(chunk) }
                    catch { await self?.captureFailed("Couldn't save audio. Check available disk space.", generation: generation) }
                    if lastMeter == 0 || HostClock.seconds(from: lastMeter, to: chunk.hostTime) > 0.08 {
                        lastMeter = chunk.hostTime
                        let level = Self.level(chunk)
                        await self?.meter(level, speaker: speaker, generation: generation)
                    }
                    if preferences.providers.transcription == .apple { continuation.yield(chunk) }
                }
                recorder.finish(); continuation.finish()
            })
            if preferences.providers.transcription == .apple {
                let transcriber = StreamTranscriber(speaker: speaker, locale: locale, sessionStart: epoch)
                tasks.append(Task { [weak self] in
                    do {
                        for try await segment in transcriber.transcribe(stream, onUpdate: { [weak self] segment, final in
                            Task { @MainActor in
                                guard let self, self.generation == generation else { return }
                                if speaker == .me { self.volatileMe = final ? "" : segment.text }
                                else { self.volatileThem = final ? "" : segment.text }
                            }
                        }) {
                            guard let self, self.generation == generation else { return }
                            self.transcript?.append(segment)
                        }
                    } catch {
                        if !(error is CancellationError) { self?.captureFailed("Transcription stopped: " + error.localizedDescription, generation: generation) }
                    }
                })
            }
        }
        isRecording = true
        DiagnosticLog.shared.record(.captureStarted)
    }
    public func stop() async throws -> Transcript {
        DiagnosticLog.shared.record(.stopRequested)
        isRecording = false
        mic?.stop(); system?.stop(); mic = nil; system = nil
        defer {
            for task in tasks { task.cancel() }
            generation = UUID()
            audioTasks = []; tasks = []; volatileMe = ""; volatileThem = ""; warning = nil
        }
        // Always finish the saved WAVs before returning or protecting them.
        for task in audioTasks { await task.value }
        DiagnosticLog.shared.record(.audioDrained)
        let speechTasks = tasks
        do {
            try await AsyncDeadline.run(for: .seconds(20)) {
                for task in speechTasks { await task.value }
            }
            try Task.checkCancellation()
        } catch {
            if error is AsyncDeadline.TimedOut { DiagnosticLog.shared.record(.speechTimedOut) }
            throw error
        }
        DiagnosticLog.shared.record(.speechFinished, count: transcript?.segments.count ?? 0)
        if let failure = failures.first { throw HushError.message(failure) }
        return transcript ?? Transcript(locale: Locale.current.identifier)
    }
    // MARK: Preview

    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// For `--demo` only: animated levels and a scripted transcript. No microphone, tap or file is used.
    public func startPreview(lines: [(Speaker, String)]) {
        guard !isRecording, !lines.isEmpty else { return }
        let begin = Date.now
        startedAt = begin; transcript = Transcript(startedAt: begin, locale: "en-US"); warning = nil
        inputName = "MacBook Pro Microphone"; isRecording = true
        meLevels = Array(repeating: 0, count: 96); themLevels = meLevels
        previewTask = Task { [weak self] in
            var line = 0, word = 0, pause = 6
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                guard let self else { return }
                let (speaker, text) = lines[line % lines.count]
                let words = text.split(separator: " ")
                let talking = pause == 0
                func level(_ active: Bool) -> Double { active ? Double.random(in: 0.25...0.85) : Double.random(in: 0...0.04) }
                self.meLevels.removeFirst(); self.meLevels.append(level(talking && speaker == .me))
                self.themLevels.removeFirst(); self.themLevels.append(level(talking && speaker == .them))
                if pause > 0 { pause -= 1; continue }
                if Int.random(in: 0...2) == 0 { continue }
                word += 1
                let partial = words.prefix(word).joined(separator: " ")
                if speaker == .me { self.volatileMe = partial } else { self.volatileThem = partial }
                if word >= words.count {
                    let elapsed = Date.now.timeIntervalSince(begin)
                    self.transcript?.append(TranscriptSegment(speaker: speaker, start: max(0, elapsed - Double(words.count) * 0.3), end: elapsed, text: text))
                    self.volatileMe = ""; self.volatileThem = ""
                    line += 1; word = 0; pause = 8
                }
            }
        }
    }
    public func stopPreview() -> Transcript {
        previewTask?.cancel(); previewTask = nil
        isRecording = false; volatileMe = ""; volatileThem = ""; warning = nil
        return transcript ?? Transcript(locale: "en-US")
    }

    public func checkSilence(duringCall: Bool) {
        if duringCall && !callPresent { lastHeardThem = .now }
        callPresent = duringCall
        if duringCall && Date.now.timeIntervalSince(lastHeardThem) >= 20 {
            if warning == nil {
                warning = "Couldn't hear the other side. Allow Hush in Screen & System Audio Recording, then start a new recording."
                settingsLink = Self.systemAudioSettings
            }
        }
    }
    private func captureFailed(_ message: String, generation: UUID) {
        guard self.generation == generation else { return }
        if !failures.contains(message) { failures.append(message) }; warning = message
    }
    private func meter(_ value: Double, speaker: Speaker, generation: UUID) {
        guard self.generation == generation else { return }
        if speaker == .me { meLevels.removeFirst(); meLevels.append(value) }
        else {
            themLevels.removeFirst(); themLevels.append(value)
            if value > 0.015 { lastHeardThem = .now }
        }
    }
    nonisolated private static func level(_ chunk: AudioChunk) -> Double {
        let buffer = chunk.buffer
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 8) { sum += data[0][i] * data[0][i] }
        return min(1, Double((sum / Float(max(1, count / 8))).squareRoot()) * 5)
    }
}
