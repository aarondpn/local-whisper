import ApplicationServices

enum AccessibilityTimeout {
    /// Process-wide default for AX messaging. Without it every AX call waits up to the
    /// system default of ~6 s for an unresponsive target app — and context capture and
    /// focused-field detection run on the main thread, where a stall that long gets the
    /// hotkey event tap disabled by macOS and key-ups lost.
    private static let defaultSeconds: Float = 1.0

    /// Applies `defaultSeconds` to every AX element this process creates. Setting the
    /// timeout on the system-wide element is the documented way to change the default.
    static func install() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), defaultSeconds)
    }
}
