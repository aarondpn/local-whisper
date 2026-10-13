import AVFoundation
import Foundation

/// Captures microphone audio as 16 kHz mono PCM.
///
/// All engine work runs on a private serial queue: creating and starting an
/// `AVAudioEngine` can block for a second or more (Bluetooth profile switches, a
/// just-woken HAL), and doing that on the main thread stalls the hotkey event tap
/// until macOS disables it — which is how key-ups get lost. Calls are enqueued
/// synchronously in call order, so a `discardRecording()` issued after a
/// `startRecording(...)` always runs after it, even if the start is still in flight.
/// The async entry points are `@MainActor` so that ordering holds regardless of
/// whether the toolchain runs nonisolated async functions on the caller's actor
/// (`NonisolatedNonsendingByDefault`) — without it they would hop to the global
/// executor before enqueuing, and a later synchronous discard could overtake them.
final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aarondpn.local-whisper.audio-recorder", qos: .userInitiated)
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    // Confined to `queue`.
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var accumulator: PCMAccumulator?

    /// `onLevelUpdate` is delivered on the main queue. `onPCMFrames` is an optional live
    /// consumer of the converted 16 kHz mono Float32 frames, invoked on the tap thread
    /// with a copy of each buffer. The Int16/WAV accumulation is unaffected, so the full
    /// recording always exists alongside the live feed.
    @MainActor
    func startRecording(
        onLevelUpdate: @escaping @Sendable (Float) -> Void,
        onPCMFrames: (@Sendable ([Float]) -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.start(onLevelUpdate: onLevelUpdate, onPCMFrames: onPCMFrames)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture and returns everything recorded as a WAV.
    @MainActor
    func stopRecording() async -> Data {
        await withCheckedContinuation { continuation in
            queue.async {
                let pcm = self.stop()
                continuation.resume(returning: self.createWAV(from: pcm))
            }
        }
    }

    /// Stops capture and drops the audio. Fire-and-forget; safe when nothing is running.
    func discardRecording() {
        queue.async {
            _ = self.stop()
        }
    }

    private func start(onLevelUpdate: @escaping @Sendable (Float) -> Void, onPCMFrames: (@Sendable ([Float]) -> Void)?) throws {
        // Defensive: never leave a previous engine running underneath a new one.
        _ = stop()

        // Build a fresh engine every session. AVAudioEngine caches its input node and the
        // hardware format at construction time; after a sleep/wake cycle or an input-device
        // change those go stale, and a reused engine then captures silence or fails to start.
        // Recreating runs once per hotkey press (not in any hot path), so the cost is trivial
        // and it makes capture survive sleep, wake, and device swaps without a restart.
        let engine = AVAudioEngine()

        let storedUID = UserDefaults.standard.string(forKey: SettingsKeys.selectedInputDeviceUID) ?? ""
        if !storedUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: storedUID) {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // A disconnected or not-yet-ready input device reports a 0 Hz / 0-channel format.
        // Fail loudly here so the error surfaces to the user instead of silently recording
        // nothing and shipping an empty clip to the transcription provider.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputAvailable
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw RecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterCreationFailed
        }

        // A fresh accumulator per session: a late buffer from a previous engine can never
        // bleed into this recording.
        let accumulator = PCMAccumulator()
        let targetSampleRate = self.targetSampleRate

        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            let ratio = targetSampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, outputBuffer.frameLength > 0 {
                accumulator.append(outputBuffer)
                let level = Self.level(of: outputBuffer)
                DispatchQueue.main.async {
                    onLevelUpdate(level)
                }
                if let onPCMFrames, let floatData = outputBuffer.floatChannelData {
                    // Copy out — the converter reuses the buffer after this closure returns.
                    let frames = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outputBuffer.frameLength)))
                    onPCMFrames(frames)
                }
            }
        }

        do {
            try engine.start()
        } catch {
            // If start fails, make sure we don't leak the tap we just installed.
            inputNode.removeTap(onBus: 0)
            throw error
        }

        self.engine = engine
        self.tapInstalled = true
        self.accumulator = accumulator
    }

    /// Returns the raw PCM captured so far. Idempotent.
    private func stop() -> Data {
        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            if engine.isRunning {
                engine.stop()
            }
        }
        engine = nil
        tapInstalled = false
        let pcm = accumulator?.take() ?? Data()
        accumulator = nil
        return pcm
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]

        var sum: Float = 0
        for i in 0..<frameCount {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }

    private func createWAV(from pcmData: Data) -> Data {
        let sampleRate: UInt32 = UInt32(targetSampleRate)
        let channels: UInt16 = UInt16(targetChannels)
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        return header + pcmData
    }
}

enum RecorderError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        case .noInputAvailable: return "No microphone input available"
        }
    }
}

/// Int16 PCM written on the audio tap thread and drained on the recorder queue.
private final class PCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelData = floatData[0]

        var int16Data = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1, min(1, channelData[i]))
            int16Data[i] = Int16(sample * Float(Int16.max))
        }

        lock.lock()
        defer { lock.unlock() }
        int16Data.withUnsafeBufferPointer { ptr in
            data.append(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let taken = data
        data = Data()
        return taken
    }
}
