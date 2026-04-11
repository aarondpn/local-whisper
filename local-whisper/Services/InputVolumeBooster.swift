import CoreAudio

final class InputVolumeBooster {
    private var previousVolumes: [(channel: UInt32, volume: Float32)] = []
    private var boostedDeviceID: AudioDeviceID?

    func boost() {
        guard let deviceID = activeInputDevice() else { return }

        let channels = volumeChannels(for: deviceID)
        guard !channels.isEmpty else {
            Log.coordinator.info("Input device has no adjustable volume channels")
            return
        }

        previousVolumes = channels.compactMap { channel in
            guard let vol = getVolume(deviceID, channel: channel) else { return nil }
            return (channel, vol)
        }
        boostedDeviceID = deviceID

        for channel in channels {
            setVolume(deviceID, channel: channel, volume: 1.0)
        }
        Log.coordinator.info("Input volume boosted to max (\(previousVolumes.count) channel(s) saved)")
    }

    func restore() {
        guard let deviceID = boostedDeviceID else { return }

        for entry in previousVolumes {
            setVolume(deviceID, channel: entry.channel, volume: entry.volume)
        }
        Log.coordinator.info("Input volume restored to previous levels")

        previousVolumes = []
        boostedDeviceID = nil
    }

    // MARK: - Private

    private func activeInputDevice() -> AudioDeviceID? {
        let storedUID = UserDefaults.standard.string(forKey: SettingsKeys.selectedInputDeviceUID) ?? ""
        if !storedUID.isEmpty, let deviceID = AudioDeviceManager.deviceID(forUID: storedUID) {
            return deviceID
        }
        return defaultInputDevice()
    }

    private func defaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }

    /// Returns channels that have a settable volume scalar.
    /// Tries master (element 0) first; if not available, tries channels 1 and 2.
    private func volumeChannels(for deviceID: AudioDeviceID) -> [UInt32] {
        if hasVolume(deviceID, channel: 0) {
            return [0]
        }

        var channels: [UInt32] = []
        for ch: UInt32 in 1...2 {
            if hasVolume(deviceID, channel: ch) {
                channels.append(ch)
            }
        }
        return channels
    }

    private func hasVolume(_ deviceID: AudioDeviceID, channel: UInt32) -> Bool {
        var address = volumeAddress(channel: channel)
        return AudioObjectHasProperty(deviceID, &address)
    }

    private func getVolume(_ deviceID: AudioDeviceID, channel: UInt32) -> Float32? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress(channel: channel)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    private func setVolume(_ deviceID: AudioDeviceID, channel: UInt32, volume: Float32) {
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress(channel: channel)

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            Log.coordinator.error("Failed to set input volume on channel \(channel): \(status)")
        }
    }

    private func volumeAddress(channel: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: channel
        )
    }
}
