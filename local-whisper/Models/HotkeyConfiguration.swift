import Carbon
import Foundation

struct HotkeyConfiguration: Equatable {
    var keyCode: UInt16
    var modifiers: CGEventFlags

    var isConfigured: Bool {
        keyCode != 999
    }

    var displayString: String {
        guard isConfigured else { return "Not Set" }

        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("^") }
        if modifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
        if modifiers.contains(.maskShift) { parts.append("\u{21E7}") }
        if modifiers.contains(.maskCommand) { parts.append("\u{2318}") }

        let keyName = Self.keyCodeToString(keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    private static func keyCodeToString(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_RightShift: return "Right Shift"
        case kVK_RightOption: return "Right Option"
        case kVK_RightControl: return "Right Control"
        case kVK_Function: return "Fn"
        default:
            let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            guard let data = layoutData else { return "Key \(keyCode)" }
            let layout = unsafeBitCast(data, to: CFData.self)
            let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)

            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0

            UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: SettingsKeys.hotkeyKeyCode)
        UserDefaults.standard.set(modifiers.rawValue, forKey: SettingsKeys.hotkeyModifiers)
    }

    static func load() -> HotkeyConfiguration {
        let keyCode = UserDefaults.standard.integer(forKey: SettingsKeys.hotkeyKeyCode)
        let modifiers = UserDefaults.standard.integer(forKey: SettingsKeys.hotkeyModifiers)
        return HotkeyConfiguration(
            keyCode: UInt16(keyCode),
            modifiers: CGEventFlags(rawValue: UInt64(modifiers))
        )
    }
}
