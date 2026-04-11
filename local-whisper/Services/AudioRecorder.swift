import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioData = Data()
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private var onLevelUpdate: ((Float) -> Void)?
    private var tapInstalled = false

    func startRecording(onLevelUpdate: @escaping (Float) -> Void) throws {
        // Defensive: if a previous session leaked its tap (e.g. engine stopped
        // out of band via route change), remove it before installing a new one.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        self.onLevelUpdate = onLevelUpdate
        audioData = Data()

        let storedUID = UserDefaults.standard.string(forKey: SettingsKeys.selectedInputDeviceUID) ?? ""
        if !storedUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: storedUID) {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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

        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let ratio = targetSampleRate / inputFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, outputBuffer.frameLength > 0 {
                self.appendPCMData(from: outputBuffer)
                self.updateLevel(from: outputBuffer)
            }
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            // If start fails, make sure we don't leak the tap we just installed.
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stopRecording() -> Data {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        onLevelUpdate = nil

        return createWAV(from: audioData)
    }

    private func appendPCMData(from buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelData = floatData[0]

        var int16Data = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1, min(1, channelData[i]))
            int16Data[i] = Int16(sample * Float(Int16.max))
        }

        int16Data.withUnsafeBufferPointer { ptr in
            audioData.append(UnsafeBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]

        var sum: Float = 0
        for i in 0..<frameCount {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 50) / 50))

        DispatchQueue.main.async { [weak self] in
            self?.onLevelUpdate?(normalized)
        }
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

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        }
    }
}
