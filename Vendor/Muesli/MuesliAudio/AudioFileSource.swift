import AVFAudio

/// Feeds an audio file through the same pipeline as live capture. Used for
/// `muesli transcribe <file>` and for tests.
public enum AudioFileSource {
    public static func chunks(url: URL, framesPerChunk: AVAudioFrameCount = 8192) throws -> AsyncStream<AudioChunk> {
        let reader = try Reader(url: url, frames: framesPerChunk)
        // Pull one buffer at a time. A long saved meeting must not be queued in RAM.
        return AsyncStream(unfolding: { reader.next() })
    }
    private final class Reader: @unchecked Sendable {
        let file: AVAudioFile
        let frames: AVAudioFrameCount
        init(url: URL, frames: AVAudioFrameCount) throws { file = try AVAudioFile(forReading: url); self.frames = frames }
        func next() -> AudioChunk? {
            guard !Task.isCancelled, file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
            do { try file.read(into: buffer, frameCount: frames) } catch { return nil }
            return buffer.frameLength > 0 ? AudioChunk(buffer: buffer) : nil
        }
    }
}
