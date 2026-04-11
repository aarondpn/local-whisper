import AppKit
import Foundation

final class TextInsertionService {
    func insertText(_ text: String, pressEnterAfterPaste: Bool = false) async {
        let frontApp = NSWorkspace.shared.frontmostApplication
        Log.textInsertion.info("insertText called, frontmost app: \(frontApp?.bundleIdentifier ?? "nil") (\(frontApp?.localizedName ?? "nil"))")

        guard hasFocusedTextField() else {
            Log.textInsertion.info("No focused text field, copying to clipboard (\(text.count) chars)")
            NSPasteboard.general.clearContents()
            let ok = NSPasteboard.general.setString(text, forType: .string)
            Log.textInsertion.info("Clipboard setString returned \(ok)")
            return
        }

        Log.textInsertion.info("Focused text field detected, simulating paste")

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }
        Log.textInsertion.debug("Saved \(previousContents?.count ?? 0) previous clipboard item(s)")

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        try? await Task.sleep(for: .milliseconds(150))

        if pressEnterAfterPaste {
            simulateEnterKey()
            try? await Task.sleep(for: .milliseconds(50))
        }

        if let previousContents, !previousContents.isEmpty {
            Log.textInsertion.debug("Restoring previous clipboard contents")
            pasteboard.clearContents()
            for (typeRaw, data) in previousContents {
                let type = NSPasteboard.PasteboardType(typeRaw)
                pasteboard.setData(data, forType: type)
            }
        }
    }

    private func hasFocusedTextField() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Log.textInsertion.debug("hasFocusedTextField: no frontmost app")
            return false
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let focusedElement else {
            Log.textInsertion.debug("hasFocusedTextField: no focused element (AX result: \(result.rawValue))")
            return false
        }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            Log.textInsertion.warning("hasFocusedTextField: focused element was not AXUIElement")
            return false
        }
        let element = focusedElement as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? "nil"
        Log.textInsertion.debug("hasFocusedTextField: focused element role=\(role)")

        let textRoles: Set<String> = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
        ]
        if textRoles.contains(role) {
            Log.textInsertion.debug("hasFocusedTextField: matched text role")
            return true
        }

        // Container roles advertise kAXSelectedTextRangeAttribute even when nothing
        // editable is focused inside them — a paste goes nowhere and then the clipboard
        // restore path clobbers the transcription. Reject them up front.
        let nonEditableContainers: Set<String> = [
            "AXWebArea", kAXGroupRole as String, kAXScrollAreaRole as String, kAXSplitGroupRole as String,
        ]
        if nonEditableContainers.contains(role) {
            Log.textInsertion.debug("hasFocusedTextField: rejecting container role")
            return false
        }

        // Probe whether the element's selected text is writable. This is the real
        // "is this an editable text input" test and catches custom roles that the
        // named list misses (some Electron apps, native controls without a standard role).
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        if settableResult == .success, settable.boolValue {
            Log.textInsertion.debug("hasFocusedTextField: kAXSelectedTextAttribute is settable")
            return true
        }

        Log.textInsertion.debug("hasFocusedTextField: no match (role=\(role), settableResult=\(settableResult.rawValue), settable=\(settable.boolValue))")
        return false
    }

    private func simulateEnterKey() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) // Return key
        keyDown?.flags = []
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        keyUp?.flags = []
        keyUp?.post(tap: .cghidEventTap)
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
