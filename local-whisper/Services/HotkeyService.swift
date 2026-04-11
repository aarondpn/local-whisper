import Carbon
import Cocoa
import Foundation

final class HotkeyService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    private var retryTimer: Timer?

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?
    var configuration: HotkeyConfiguration = .load()

    deinit {
        // The tap callback holds an unretained pointer to `self`; it must be torn down
        // before the instance dies or the next event will dereference freed memory.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        retryTimer?.invalidate()
    }

    func start() {
        stop()
        reloadConfiguration()

        if !PermissionChecker.hasAccessibilityPermission {
            Log.hotkey.warning("No accessibility permission, requesting and scheduling retry...")
            PermissionChecker.requestAccessibilityPermission()
            startRetryTimer()
            return
        }

        createEventTap()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
    }

    func reloadConfiguration() {
        configuration = .load()
        Log.hotkey.info("Configuration: keyCode=\(self.configuration.keyCode), modifiers=\(self.configuration.modifiers.rawValue), configured=\(self.configuration.isConfigured)")
    }

    private func startRetryTimer() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if PermissionChecker.hasAccessibilityPermission {
                Log.hotkey.info("Accessibility permission granted, creating event tap...")
                self.retryTimer?.invalidate()
                self.retryTimer = nil
                self.createEventTap()
            }
        }
    }

    private func createEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.hotkey.error("Failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.hotkey.info("Event tap created and enabled")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.hotkey.warning("Re-enabled event tap after timeout")
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // ESC cancels a running recording/transcription without consuming the event when
        // nothing is in flight. The callback decides whether to act.
        if type == .keyDown && Int(keyCode) == kVK_Escape && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
            if let onEscape {
                onEscape()
            }
            // Don't swallow — other apps may want ESC too.
            return Unmanaged.passRetained(event)
        }

        guard configuration.isConfigured else {
            return Unmanaged.passRetained(event)
        }

        // Fn key only produces flagsChanged events, handle separately
        if configuration.keyCode == UInt16(kVK_Function) && configuration.modifiers.isEmpty {
            if type == .flagsChanged {
                let fnDown = flags.contains(.maskSecondaryFn)
                if fnDown && !isKeyDown {
                    isKeyDown = true
                    Log.hotkey.debug("Fn key DOWN")
                    onKeyDown?()
                    return nil
                } else if !fnDown && isKeyDown {
                    isKeyDown = false
                    Log.hotkey.debug("Fn key UP")
                    onKeyUp?()
                    return nil
                }
            }
            return Unmanaged.passRetained(event)
        }

        let configModifiers = configuration.modifiers
        let hasModifiers = !configModifiers.isEmpty

        if hasModifiers {
            if type == .keyDown || type == .keyUp {
                let modifiersMatch = flags.contains(configModifiers)
                let keyMatches = keyCode == configuration.keyCode

                if type == .keyDown && modifiersMatch && keyMatches {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if !isRepeat && !isKeyDown {
                        isKeyDown = true
                        Log.hotkey.debug("Key DOWN (keyCode=\(keyCode))")
                        onKeyDown?()
                    }
                    return nil
                } else if type == .keyUp && keyMatches && isKeyDown {
                    isKeyDown = false
                    Log.hotkey.debug("Key UP (keyCode=\(keyCode))")
                    onKeyUp?()
                    return nil
                }
            }
        } else {
            if type == .keyDown && keyCode == configuration.keyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat && !isKeyDown {
                    isKeyDown = true
                    Log.hotkey.debug("Key DOWN (keyCode=\(keyCode))")
                    onKeyDown?()
                }
                return nil
            } else if type == .keyUp && keyCode == configuration.keyCode && isKeyDown {
                isKeyDown = false
                Log.hotkey.debug("Key UP (keyCode=\(keyCode))")
                onKeyUp?()
                return nil
            }
        }

        return Unmanaged.passRetained(event)
    }
}
