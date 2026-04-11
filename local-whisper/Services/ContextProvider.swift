import AppKit
import ApplicationServices
import Foundation

/// Captures dynamic context from the currently-focused app via the Accessibility API and
/// merges it with the static per-profile prompt. Fed to Whisper's `prompt` parameter to
/// bias decoding toward the vocabulary, spelling, and style the user is currently working in.
///
/// Design: Whisper's prompt is literally "text that precedes the audio." We read the text
/// before the caret and use one of three strategies depending on what we find:
///
/// 1. If the current line starts with a shell prompt marker (`❯`, `$`, `>`, etc.) we're in
///    a terminal — use only that line's command, never walk back into scrollback.
/// 2. If the current line already has substantial content (≥15 chars), use it alone —
///    mid-sentence dictation is its own best context.
/// 3. Otherwise (prose/code with an empty or very short current line — e.g. the user just
///    pressed Enter to start a new paragraph or code line) walk backward up to 3 non-blank
///    lines to gather surrounding context. Safe outside terminals because "walking back"
///    means "the user's own previous lines," not shell output.
enum ContextProvider {
    /// Cap on captured context length in UTF-8 bytes, below the ~896-byte API limit with
    /// room for the profile prompt on top.
    private static let maxContextBytes = 240

    /// Current line length at which we stop and don't bother walking back for more context.
    private static let currentLineSufficientChars = 15

    /// Max number of non-blank prior lines collected when walking back in non-terminal apps.
    private static let maxNonBlankLinesBack = 3

    /// Safety cap on total physical lines iterated during walkback, regardless of how many
    /// were blank. Prevents runaway iteration over pathologically long AX values.
    private static let maxPhysicalLinesIterated = 20

    /// Target character budget when walking back. Once reached, we stop collecting more
    /// lines even if we haven't hit the non-blank limit.
    private static let lookbackTargetChars = 150

    /// Conservative ceiling for the combined (profile + dynamic) prompt, below Groq's
    /// 896-byte limit. Truncated by UTF-8 byte count since the APIs count bytes, not
    /// Swift grapheme clusters.
    private static let maxPromptBytes = 700

    /// First characters that commonly mark a shell prompt. Used both for detecting
    /// terminal mode and for stripping prompt prefixes from command lines.
    private static let shellPromptChars: Set<Character> = ["$", "❯", "›", ">", "#", "%", "→", "►", "▶"]

    /// Bundle IDs of apps where context must come from a shell-prompt line only. Walking
    /// back in these apps pulls in shell output or full-screen TUIs (Claude Code, vim,
    /// tmux status bars), which are almost always noise for Whisper biasing.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
    ]

    /// Minimum fraction of a line's non-whitespace characters that must be letters or
    /// digits for the line to survive `sanitizeLine`. Set conservatively — only lines
    /// overwhelmingly made of decoration (box-drawing runs, separator lines, emoji
    /// strips) should fail. Normal prose, code, and shell commands clear this easily.
    private static let minWordCharRatio = 0.3

    /// Captures the best available dynamic context for the frontmost app, or nil if the
    /// feature is disabled, the app is excluded, or nothing useful could be read. Called
    /// synchronously at key-up time so the caret reflects the user's intent at that moment.
    static func captureDynamicContext() -> String? {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.useDynamicContext) else { return nil }
        guard AXIsProcessTrusted() else { return nil }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleID, loadExcludedApps().contains(where: { $0.bundleID == bundleID }) {
            return nil
        }

        let isTerminal = bundleID.map(terminalBundleIDs.contains) ?? false

        if let context = contextBeforeCaret(isTerminal: isTerminal) {
            return context
        }
        if UserDefaults.standard.bool(forKey: SettingsKeys.useWindowTitleFallback),
           let title = focusedWindowTitle() {
            return "Context: \(title)"
        }
        return nil
    }

    // MARK: - Excluded apps persistence

    static func loadExcludedApps() -> [ExcludedContextApp] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.excludedContextApps) else { return [] }
        return (try? JSONDecoder().decode([ExcludedContextApp].self, from: data)) ?? []
    }

    static func saveExcludedApps(_ apps: [ExcludedContextApp]) {
        do {
            let data = try JSONEncoder().encode(apps)
            UserDefaults.standard.set(data, forKey: SettingsKeys.excludedContextApps)
        } catch {
            Log.coordinator.error("Failed to save excluded context apps: \(error)")
        }
    }

    /// Merges a base (profile) prompt with captured dynamic context, truncating the
    /// combined string from the left by UTF-8 byte count so the most-recent context
    /// survives the API's byte-level prompt limit.
    static func combine(basePrompt: String?, dynamicContext: String?) -> String? {
        var parts: [String] = []
        if let basePrompt, !basePrompt.isEmpty {
            parts.append(basePrompt)
        }
        if let dynamicContext, !dynamicContext.isEmpty {
            parts.append(dynamicContext)
        }
        guard !parts.isEmpty else { return nil }

        let combined = parts.joined(separator: "\n\n")
        return truncateFromLeft(combined, maxBytes: maxPromptBytes)
    }

    // MARK: - Accessibility readers

    /// Reads the text before the caret in the focused UI element and runs it through the
    /// three-strategy context extractor. Returns nil if the element exposes no text.
    private static func contextBeforeCaret(isTerminal: Bool) -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let value = valueRef as? String, !value.isEmpty else {
            return nil
        }

        let nsValue = value as NSString
        var caretOffset = nsValue.length

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let axValue = rangeRef as! AXValue
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &range) {
                caretOffset = range.location
            }
        }

        let endOffset = min(max(0, caretOffset), nsValue.length)
        guard endOffset > 0 else { return nil }

        let textBeforeCaret = nsValue.substring(with: NSRange(location: 0, length: endOffset))
        return extractContext(from: textBeforeCaret, isTerminal: isTerminal)
    }

    /// Chooses the best context for the text preceding the caret. Exposed `internal` so
    /// the logic can be exercised from tests without a live AX element.
    ///
    /// Strategy:
    /// 1. If `isTerminal` is true or the current (last) line starts with a shell prompt
    ///    marker, use only the current line's command — never walk back into scrollback.
    ///    In known terminals, if there's no shell prompt, return nil: the line is either
    ///    shell output or a full-screen TUI (Claude Code, vim, tmux) and walking back
    ///    would pull in unrelated text.
    /// 2. If the current line already has ≥`currentLineSufficientChars` of content,
    ///    return just that.
    /// 3. Otherwise walk backward collecting up to `maxNonBlankLinesBack` non-blank
    ///    lines until we have ~`lookbackTargetChars` of content.
    static func extractContext(from textBeforeCaret: String, isTerminal: Bool = false) -> String? {
        let lines = textBeforeCaret.components(separatedBy: CharacterSet.newlines)
        guard !lines.isEmpty else { return nil }

        let rawCurrentLine = lines.last ?? ""
        let currentLineTrimmed = rawCurrentLine.trimmingCharacters(in: .whitespaces)
        let hasShellPrompt = currentLineTrimmed.first.map(shellPromptChars.contains) ?? false

        // Strategy 1: terminal mode. Known terminal app OR a shell-prompt-looking line.
        if isTerminal || hasShellPrompt {
            guard hasShellPrompt else { return nil }
            let sanitized = sanitizeLine(rawCurrentLine)
            guard sanitized.count >= 2 else { return nil }
            return truncateFromLeft(sanitized, maxBytes: maxContextBytes)
        }

        let currentLine = sanitizeLine(rawCurrentLine)

        // Strategy 2: substantial current line, use it alone.
        if currentLine.count >= currentLineSufficientChars {
            return truncateFromLeft(currentLine, maxBytes: maxContextBytes)
        }

        // Strategy 3: walk back through previous non-blank lines for prose/code context.
        var collected: [String] = []
        var totalChars = 0
        if currentLine.count >= 2 {
            collected.append(currentLine)
            totalChars = currentLine.count
        }

        var nonBlankWalked = 0
        var iterated = 0

        for rawLine in lines.dropLast().reversed() {
            iterated += 1
            if iterated > maxPhysicalLinesIterated { break }

            let sanitized = sanitizeLine(rawLine)
            if sanitized.isEmpty { continue }

            nonBlankWalked += 1
            if nonBlankWalked > maxNonBlankLinesBack { break }

            collected.insert(sanitized, at: 0)
            totalChars += sanitized.count + 1

            if totalChars >= lookbackTargetChars { break }
        }

        guard !collected.isEmpty else { return nil }
        let joined = collected.joined(separator: " ")
        return truncateFromLeft(joined, maxBytes: maxContextBytes)
    }

    /// Trims whitespace, strips a leading shell prompt marker, and drops lines that
    /// are obviously UI chrome rather than meaningful context. Returns an empty string
    /// for lines that can't be used.
    static func sanitizeLine(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return "" }

        if let first = trimmed.first, shellPromptChars.contains(first) {
            let chars = Array(trimmed)
            var idx = 1
            while idx < chars.count && chars[idx].isWhitespace {
                idx += 1
            }
            trimmed = String(chars[idx...]).trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { return "" }
        }

        // Reject lines dominated by decoration: box-drawing runs, separator lines of
        // dashes/equals/asterisks, emoji-only status bars. The threshold is intentionally
        // lenient so only overwhelmingly non-textual lines fail.
        let scalars = trimmed.unicodeScalars
        var nonWhitespace = 0
        var wordChars = 0
        for scalar in scalars {
            if CharacterSet.whitespaces.contains(scalar) { continue }
            nonWhitespace += 1
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                wordChars += 1
            }
        }
        guard nonWhitespace > 0 else { return "" }
        let ratio = Double(wordChars) / Double(nonWhitespace)
        if ratio < minWordCharRatio {
            return ""
        }

        return trimmed
    }

    /// Returns the title of the currently focused window via AX, or nil if unavailable.
    /// Used as a last-resort hint when the current line is empty.
    private static func focusedWindowTitle() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        ) == .success, let appRef,
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success, let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &titleRef
        ) == .success, let title = titleRef as? String else { return nil }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Byte-aware truncation

    /// Drops Characters from the left of `s` until the remainder fits in `maxBytes` of
    /// UTF-8. Walks backward one whole Character at a time so the result is always a
    /// valid String — never a split scalar.
    private static func truncateFromLeft(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }

        var byteCount = 0
        var cursor = s.endIndex
        while cursor > s.startIndex {
            let prev = s.index(before: cursor)
            let charBytes = String(s[prev..<cursor]).utf8.count
            if byteCount + charBytes > maxBytes { break }
            byteCount += charBytes
            cursor = prev
        }
        return String(s[cursor..<s.endIndex])
    }
}
