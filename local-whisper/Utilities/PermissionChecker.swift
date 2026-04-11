import AVFoundation
import Cocoa

enum PermissionChecker {
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var microphonePermissionStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static var allPermissionsGranted: Bool {
        hasAccessibilityPermission && microphonePermissionStatus == .granted
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func checkMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

enum PermissionStatus {
    case granted, notDetermined, denied
}
