import Foundation

enum AudioProcessor {
    static func trimSilence(from wavData: Data) -> Data {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.trimSilenceEnabled) else {
            Log.audio.info("Silence trimming disabled, skipping")
            return wavData
        }

        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("lw_input_\(UUID().uuidString).wav")
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("lw_output_\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            try wavData.write(to: inputURL)
        } catch {
            Log.audio.error("Failed to write temp file: \(error)")
            return wavData
        }

        guard let ffmpeg = findFFmpeg() else {
            Log.audio.warning("ffmpeg not found, skipping silence removal")
            return wavData
        }

        let threshold = UserDefaults.standard.double(forKey: SettingsKeys.silenceThresholdDB)
        let minDuration = UserDefaults.standard.double(forKey: SettingsKeys.silenceMinDuration)

        let filter = [
            "silenceremove=start_periods=1:start_threshold=\(Int(threshold))dB:start_duration=\(minDuration):start_silence=0.15",
            "areverse",
            "silenceremove=start_periods=1:start_threshold=\(Int(threshold))dB:start_duration=\(minDuration):start_silence=0.15",
            "areverse",
        ].joined(separator: ",")

        Log.audio.info("Filter: threshold=\(Int(threshold))dB, minDuration=\(minDuration)s")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-i", inputURL.path,
            "-af", filter,
            "-ar", "16000", "-ac", "1",
            outputURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.audio.error("ffmpeg execution failed: \(error)")
            return wavData
        }

        guard process.terminationStatus == 0 else {
            Log.audio.error("ffmpeg exited with status \(process.terminationStatus)")
            return wavData
        }

        do {
            let processed = try Data(contentsOf: outputURL)
            let savedPct = wavData.count > 0 ? Int((1.0 - Double(processed.count) / Double(wavData.count)) * 100) : 0
            Log.audio.info("\(wavData.count) -> \(processed.count) bytes (\(savedPct)% reduced)")
            return processed
        } catch {
            Log.audio.error("Failed to read processed file: \(error)")
            return wavData
        }
    }

    private static func findFFmpeg() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
