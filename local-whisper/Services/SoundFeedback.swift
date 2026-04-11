import AppKit

enum SoundFeedback {
    static func playStartSound() {
        NSSound(named: "Tink")?.play()
    }

    static func playStopSound() {
        NSSound(named: "Pop")?.play()
    }

    static func playErrorSound() {
        NSSound(named: "Basso")?.play()
    }
}
