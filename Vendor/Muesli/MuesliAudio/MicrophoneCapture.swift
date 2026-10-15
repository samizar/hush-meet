import AVFoundation

/// Captures the default input device with `AVAudioEngine`. This is "Me".
public final class MicrophoneCapture: @unchecked Sendable {
    public enum CaptureError: Error, LocalizedError {
        case accessDenied

        public var errorDescription: String? {
            "Microphone access denied. Grant it to Hush in System Settings → Privacy & Security → Microphone."
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Starts capture. The stream ends when `stop()` is called.
    public func start() async throws -> AsyncStream<AudioChunk> {
        guard await Self.requestAccess() else { throw CaptureError.accessDenied }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
        self.continuation = continuation

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            owned.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
            for (src, dst) in zip(source, destination) {
                if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(src.mDataByteSize)) }
            }
            continuation.yield(AudioChunk(buffer: owned, hostTime: time.hostTime))
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
