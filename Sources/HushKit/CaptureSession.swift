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
    public private(set) var warning: String?
    @ObservationIgnored private var mic: MicrophoneCapture?
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var audioTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var failures: [String] = []
    @ObservationIgnored private var recorders: [Speaker: StreamRecorder] = [:]
    @ObservationIgnored private var sessionEpoch: UInt64 = 0
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
        let system = SystemAudioCapture(scope: preferences.captureAllApps ? .everything : .only(AppSelector(preferences.captureApps)))
        system.onUpdate = { [weak self] update in
            Task { @MainActor in
                switch update {
                case .failed: self?.warning = "System audio stopped. Check System Settings → Privacy & Security → Screen & System Audio Recording."
                case .waiting: self?.warning = "Waiting for a selected call app."
                case .following: self?.warning = nil
                }
            }
        }
        do {
            let micStream = try await mic.start()
            let systemStream = try system.start()
            self.mic = mic; self.system = system
            let epoch = HostClock.now()
            sessionEpoch = epoch
            startedAt = .now; transcript?.startedAt = startedAt!; lastHeardThem = .now
            meLevels = Array(repeating: 0, count: 96); themLevels = meLevels
            for (speaker, source) in [(Speaker.me, micStream), (.them, systemStream)] {
                let recorder = try StreamRecorder(url: folder.appendingPathComponent(speaker.rawValue + ".wav"))
                recorders[speaker] = recorder
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recorder.url.path)
                let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
                audioTasks.append(Task.detached { [weak self] in
                    var lastMeter: UInt64 = 0
                    for await chunk in source {
                        do { try recorder.write(chunk) }
                        catch { await self?.captureFailed("Couldn't save audio. Check available disk space.") }
                        if lastMeter == 0 || HostClock.seconds(from: lastMeter, to: chunk.hostTime) > 0.08 {
                            lastMeter = chunk.hostTime
                            let level = Self.level(chunk)
                            await self?.meter(level, speaker: speaker)
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
                                    if speaker == .me { self?.volatileMe = final ? "" : segment.text }
                                    else { self?.volatileThem = final ? "" : segment.text }
                                }
                            }) {
                                self?.transcript?.append(segment)
                            }
                        } catch { self?.captureFailed("Transcription stopped: " + error.localizedDescription) }
                    })
                }
            }
            isRecording = true
        } catch {
            mic.stop(); system.stop()
            for task in audioTasks { await task.value }
            for task in tasks { task.cancel() }
            self.mic = nil; self.system = nil; tasks = []; audioTasks = []
            throw error
        }
    }
    public func stop() async throws -> Transcript {
        isRecording = false
        mic?.stop(); system?.stop(); mic = nil; system = nil
        for task in audioTasks { await task.value }
        for task in tasks { await task.value }
        audioTasks = []; tasks = []; volatileMe = ""; volatileThem = ""
        if let failure = failures.first { throw HushError.message(failure) }
        return transcript ?? Transcript(locale: Locale.current.identifier)
    }
    public func checkSilence(duringCall: Bool) {
        if duringCall && !callPresent { lastHeardThem = .now }
        callPresent = duringCall
        if duringCall && Date.now.timeIntervalSince(lastHeardThem) >= 20 {
            warning = "Couldn't hear the other side. Allow Hush in System Settings → Privacy & Security → Screen & System Audio Recording, then restart recording."
        }
    }
    private func captureFailed(_ message: String) {
        if !failures.contains(message) { failures.append(message) }; warning = message
    }
    private func meter(_ value: Double, speaker: Speaker) {
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
