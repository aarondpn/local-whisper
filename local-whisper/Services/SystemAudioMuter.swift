import CoreAudio

final class SystemAudioMuter {
    private var wasAlreadyMuted = false

    func mute() {
        guard let deviceID = defaultOutputDevice() else { return }

        wasAlreadyMuted = isMuted(deviceID)
        if wasAlreadyMuted {
            Log.coordinator.info("System audio already muted, skipping")
            return
        }

        setMute(deviceID, muted: true)
        Log.coordinator.info("System audio muted for recording")
    }

    func unmute() {
        guard !wasAlreadyMuted, let deviceID = defaultOutputDevice() else { return }

        setMute(deviceID, muted: false)
        Log.coordinator.info("System audio unmuted after recording")
    }

    // MARK: - CoreAudio helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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

        guard status == noErr, deviceID != kAudioDeviceUnknown else {
            Log.coordinator.error("Failed to get default output device: \(status)")
            return nil
        }
        return deviceID
    }

    private func isMuted(_ deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = mutePropertyAddress()

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return false }
        return muted != 0
    }

    private func setMute(_ deviceID: AudioDeviceID, muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = mutePropertyAddress()

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        if status != noErr {
            Log.coordinator.error("Failed to set mute state: \(status)")
        }
    }

    private func mutePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
