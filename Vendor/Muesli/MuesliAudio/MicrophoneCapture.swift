import AVFoundation

/// Captures the default input device with `AVAudioEngine`. This is "Me".
///
/// Hush: the engine stops whenever the input device or its format changes
/// (AirPods connecting, a USB headset unplugged). Capture reinstalls its tap on
/// the new device and keeps the same stream, so a recording never goes silent.
public final class MicrophoneCapture: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case accessDenied
        case noInputDevice

        public var errorDescription: String? {
            switch self {
            case .accessDenied: "Microphone access denied. Grant it to Hush in System Settings → Privacy & Security → Microphone."
            case .noInputDevice: "No microphone is available. Connect one or choose an input in System Settings → Sound."
            }
        }
    }

    public enum Event: Sendable, Equatable {
        /// The input changed and capture resumed on the new device.
        case resumed(device: String?)
        /// The input changed and no usable device is available yet. Capture retries.
        case interrupted
    }

    private let engine = AVAudioEngine()
    private let control = DispatchQueue(label: "hush.microphone.control")
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var observer: NSObjectProtocol?
    private var restartAttempt = 0
    /// Called on an internal queue.
    public var onEvent: (@Sendable (Event) -> Void)?

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// The name of the current default input, for status text.
    public static var currentInputName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    /// Starts capture. The stream ends when `stop()` is called.
    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.requestAccess() else { throw CaptureError.accessDenied }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        try control.sync {
            self.continuation = continuation
            do {
                try installTap(continuation)
                engine.prepare()
                try engine.start()
            } catch {
                self.continuation = nil
                continuation.finish()
                throw error
            }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.control.async { self?.restart() }
            }
        }
        return stream
    }

    public func stop() {
        control.sync {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            continuation?.finish()
            continuation = nil
        }
    }

    /// Runs on `control`.
    private func installTap(_ continuation: AsyncStream<AudioChunk>.Continuation) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Installing a tap with a zero-rate format crashes; it means no input device exists.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            owned.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
            for (src, dst) in zip(source, destination) {
                if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize))) }
            }
            continuation.yield(AudioChunk(buffer: owned, hostTime: time.hostTime))
        }
    }

    /// Runs on `control`. Retries with a short back-off while a new device settles.
    private func restart() {
        guard let continuation else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try installTap(continuation)
            engine.prepare()
            try engine.start()
            restartAttempt = 0
            onEvent?(.resumed(device: Self.currentInputName))
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            restartAttempt += 1
            if restartAttempt == 1 { onEvent?(.interrupted) }
            let delay = min(5.0, 0.25 * Double(restartAttempt))
            control.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restart() }
        }
    }
}
