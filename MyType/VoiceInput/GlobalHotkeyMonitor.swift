// Abstract:
// Global hotkey monitor for voice input — intercepts the fn (Globe)
// key using CGEventTap to suppress the system emoji picker and
// toggle voice recording; a tap of right Control toggles it too (for
// external keyboards whose fn never reaches the Mac).
//
// Reference: TypeFlux (github.com/mylxsw/typeflux) EventTapHotkeyService

import AppKit
import CoreGraphics
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "GlobalHotkeyMonitor"
)

/// The fn/Globe key's virtual key code on macOS.
private let kFnKeyCode: Int = 63
/// Right Control: the same tap-to-toggle as fn, for keyboards whose fn
/// never reaches the Mac (most third-party ones handle fn in firmware).
private let kRightControlKeyCode: Int = 62
/// The device-dependent flag bit for right Control (NX_DEVICERCTLKEYMASK),
/// so left Control held at the same time doesn't count.
private let kRightControlFlag: UInt64 = 0x2000
/// The Escape key's virtual key code — used by Voice Input to let the
/// user cancel an in-progress recording from anywhere, not just the ✕
/// on the overlay capsule.
private let kEscapeKeyCode: Int = 53
/// The Space key's virtual key code — combined with fn to trigger
/// the "polish selected text" action.
private let kSpaceKeyCode: Int = 49
/// The V key — ⌃⌥V types the last dictation again.
private let kVKeyCode: Int = 9
/// The Return / Enter key's virtual key code — used to accept the
/// polish preview when it's showing.
private let kReturnKeyCode: Int = 36
/// The numeric-keypad Enter key (separate keycode from main Return).
/// Both should accept the preview.
private let kKeypadEnterKeyCode: Int = 76

/// CGEventTap C callback — forwards to the monitor instance via refcon.
private func hotkeyEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(refcon)
        .takeUnretainedValue()
    return monitor.handleEvent(type: type, event: event)
}

@MainActor @Observable
final class GlobalHotkeyMonitor {
    /// Callback fired when fn is tapped (pressed and released cleanly).
    var onHotkeyPressed: (() -> Void)?

    /// Callback fired when Escape is pressed while recording is active.
    var onCancelPressed: (() -> Void)?

    /// Callback fired on ⌃⌥V (type the last dictation again).
    var onRetypeLastPressed: (() -> Void)?

    /// Callback fired when fn+space is pressed (polish selected text).
    var onPolishHotkeyPressed: (() -> Void)?

    /// Fired when Return / keypad Enter is pressed while the polish
    /// preview is visible. The key is swallowed so it doesn't leak to
    /// the focused app (e.g., Slack would send the message).
    var onPolishAccept: (() -> Void)?
    /// Fired when Escape is pressed while the polish preview is visible.
    /// Same suppression rationale as accept.
    var onPolishCancel: (() -> Void)?

    @ObservationIgnored nonisolated(unsafe) var shouldInterceptEscape = false
    /// Set by the polish flow while the preview panel is visible. When
    /// true, Return/Enter and Escape are intercepted and routed to
    /// onPolishAccept / onPolishCancel respectively.
    @ObservationIgnored nonisolated(unsafe) var shouldInterceptPolishKeys = false

    /// These properties are accessed from the CGEventTap callback which
    /// runs on the run loop thread. They're marked `@ObservationIgnored`
    /// so the `@Observable` macro doesn't wrap them (the macro wrapper is
    /// incompatible with `nonisolated` on stored properties), and
    /// `nonisolated(unsafe)` grants the cross-actor access the callback
    /// needs. The callback itself only reads/writes simple flags and the
    /// tap pointer, so the "unsafe" escape is acceptable here.
    @ObservationIgnored nonisolated(unsafe) private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isMonitoring = false

    /// fn key state tracking (accessed from callback thread)
    @ObservationIgnored nonisolated(unsafe) private var fnIsDown = false
    @ObservationIgnored nonisolated(unsafe) private var otherKeyDuringFn = false
    /// Set when fn+space has fired this fn-hold so we don't re-trigger
    /// on auto-repeat keyDowns while space stays held.
    @ObservationIgnored nonisolated(unsafe) private var polishFiredThisFnHold = false
    /// Right Control held, and whether another key went with it (then it
    /// was a shortcut like ⌃C, not a tap).
    @ObservationIgnored nonisolated(unsafe) private var rightControlIsDown = false
    @ObservationIgnored nonisolated(unsafe) private var otherKeyDuringRightControl = false

    /// NSEvent fallback monitors (used when CGEventTap unavailable)
    @ObservationIgnored nonisolated(unsafe) private var globalMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var localMonitor: Any?

    /// Key for the fn/Globe key behavior in System Preferences.
    private static let fnUsageDomain = "com.apple.HIToolbox" as CFString
    private static let fnUsageKey = "AppleFnUsageType" as CFString

    /// Start intercepting fn key events via CGEventTap.
    /// Falls back to NSEvent monitors if Accessibility permission is missing.
    func start() {
        guard !isMonitoring else { return }

        fnIsDown = false
        otherKeyDuringFn = false

        // Disable the system emoji picker for the fn key.
        // The emoji picker operates below CGEventTap, so it cannot
        // be suppressed by returning nil. We must change the system
        // preference to "Do Nothing" (0) and restore it on stop.
        disableSystemFnEmoji()

        // Prompt for Accessibility permission if not already granted
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )

        if trusted {
            installEventTap()
        } else {
            logger.warning("Accessibility not granted — polling until granted")
            installNSEventFallback()
            // Poll every 2s until the user grants Accessibility,
            // then swap from NSEvent fallback to CGEventTap.
            pollForAccessibility()
        }

        // Key-up events missed while asleep or switched away would leave a
        // key "held": the next tap goes unseen, and a stuck fn swallows
        // every Space. Start clean after each.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.clearKeyState()
                logger.info("Key state cleared after \(name.rawValue, privacy: .public)")
            }
        }

        isMonitoring = true
    }

    /// Forget which keys are held.
    nonisolated private func clearKeyState() {
        fnIsDown = false
        otherKeyDuringFn = false
        polishFiredThisFnHold = false
        rightControlIsDown = false
        otherKeyDuringRightControl = false
    }

    /// Periodically check if Accessibility was granted. Once it is,
    /// tear down the NSEvent fallback and install CGEventTap.
    private func pollForAccessibility() {
        Task { @MainActor [weak self] in
            while let self, self.isMonitoring, self.eventTap == nil {
                try? await Task.sleep(for: .seconds(2))
                let granted = AXIsProcessTrustedWithOptions(nil)
                if granted {
                    logger.info("Accessibility granted — upgrading to CGEventTap")
                    if let m = self.globalMonitor { NSEvent.removeMonitor(m) }
                    if let m = self.localMonitor { NSEvent.removeMonitor(m) }
                    self.globalMonitor = nil
                    self.localMonitor = nil
                    self.installEventTap()
                    return
                }
            }
        }
    }

    // MARK: - System fn Key Preference

    /// Set the fn key preference to "Do Nothing" so the system emoji
    /// picker can't fire — it operates below CGEventTap and can't be
    /// suppressed any other way.
    private func disableSystemFnEmoji() {
        let current = CFPreferencesCopyValue(
            Self.fnUsageKey, Self.fnUsageDomain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        let previous = (current as? NSNumber)?.intValue ?? -1

        CFPreferencesSetValue(
            Self.fnUsageKey, 0 as CFNumber,
            Self.fnUsageDomain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(
            Self.fnUsageDomain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        logger.info("Disabled system fn emoji picker (was: \(previous))")
    }

    // MARK: - CGEventTap (preferred — can suppress emoji picker)

    private func installEventTap() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: selfPointer
        ) else {
            logger.error("Failed to create CGEventTap — falling back to NSEvent")
            installNSEventFallback()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        logger.info("Global hotkey monitor started (fn key via CGEventTap)")
    }

    // MARK: - NSEvent Fallback (cannot suppress emoji picker)

    private func installNSEventFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
        logger.info("Global hotkey monitor started (fn key via NSEvent fallback)")
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .keyDown, rightControlIsDown {
            otherKeyDuringRightControl = true
        }
        if event.type == .flagsChanged {
            handleNSFlagsChanged(event)
        } else if event.type == .keyDown,
                  event.keyCode == kEscapeKeyCode,
                  shouldInterceptEscape {
            // NSEvent can't suppress — Esc will still reach the focused
            // app — but we can at least fire the cancel callback.
            DispatchQueue.main.async { [weak self] in
                self?.onCancelPressed?()
            }
        }
    }

    private func handleNSFlagsChanged(_ event: NSEvent) {
        if event.keyCode == kRightControlKeyCode {
            handleRightControl(isDown: UInt64(event.modifierFlags.rawValue) & kRightControlFlag != 0)
            return
        }
        guard event.keyCode == kFnKeyCode else { return }
        let fnDown = event.modifierFlags.contains(.function)

        if fnDown && !fnIsDown {
            fnIsDown = true
            otherKeyDuringFn = false
        } else if !fnDown && fnIsDown {
            fnIsDown = false
            if !otherKeyDuringFn {
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyPressed?()
                }
            }
            otherKeyDuringFn = false
        }
    }

    // MARK: - Right Control

    /// A clean tap (down and up with no other key between) toggles
    /// recording, like fn.
    nonisolated private func handleRightControl(isDown: Bool) {
        if isDown {
            // Also when it already counts as held: its release was missed,
            // and this press starts a fresh tap.
            rightControlIsDown = true
            otherKeyDuringRightControl = false
        } else if !isDown && rightControlIsDown {
            rightControlIsDown = false
            if !otherKeyDuringRightControl {
                DispatchQueue.main.async { [weak self] in
                    self?.onHotkeyPressed?()
                }
            }
            otherKeyDuringRightControl = false
        }
    }

    // MARK: - Event Handling

    /// Process a CGEventTap event. Returns nil to suppress, or the event to pass through.
    nonisolated func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if macOS disabled it due to timeout. Key events
        // were missed meanwhile, so what we think is held can't be trusted.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            clearKeyState()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // --- flagsChanged: right Control tap → toggle recording ---
        if type == .flagsChanged, keyCode == kRightControlKeyCode {
            handleRightControl(isDown: event.flags.rawValue & kRightControlFlag != 0)
            return Unmanaged.passUnretained(event)
        }

        // --- flagsChanged: detect fn press/release ---
        if type == .flagsChanged {
            guard keyCode == kFnKeyCode else {
                // Another modifier joined (⌃⇧, fn+⌥): a chord, not a tap.
                if rightControlIsDown { otherKeyDuringRightControl = true }
                if fnIsDown { otherKeyDuringFn = true }
                return Unmanaged.passUnretained(event)
            }

            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let fnDown = flags.contains(.function)

            if fnDown && !fnIsDown {
                fnIsDown = true
                otherKeyDuringFn = false
                polishFiredThisFnHold = false
                return nil
            } else if !fnDown && fnIsDown {
                fnIsDown = false
                let wasCleanTap = !otherKeyDuringFn
                otherKeyDuringFn = false
                polishFiredThisFnHold = false

                if wasCleanTap {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHotkeyPressed?()
                    }
                    return nil
                }
            }

            return Unmanaged.passUnretained(event)
        }

        // A key event without the fn flag while we think fn is held: its
        // release was missed. Without this a stuck fn swallowed every Space.
        if fnIsDown, type == .keyDown || type == .keyUp, !event.flags.contains(.maskSecondaryFn) {
            fnIsDown = false
            otherKeyDuringFn = false
            polishFiredThisFnHold = false
        }

        // --- keyDown: ⌃⌥V → type the last dictation again (swallowed) ---
        if type == .keyDown, keyCode == kVKeyCode {
            let flags = event.flags
            if flags.contains(.maskControl), flags.contains(.maskAlternate),
               !flags.contains(.maskCommand), !flags.contains(.maskShift) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.onRetypeLastPressed?()
                    }
                }
                return nil
            }
        }

        // --- keyDown: fn+space → polish selected text ---
        // Suppress the space so it doesn't leak into the focused field.
        if type == .keyDown, keyCode == kSpaceKeyCode, fnIsDown {
            otherKeyDuringFn = true
            if !polishFiredThisFnHold {
                polishFiredThisFnHold = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPolishHotkeyPressed?()
                }
            }
            return nil
        }

        // --- keyDown: ⏎ / ⎋ while polish preview is showing ---
        // Routed BEFORE the existing Escape handler so polish-cancel
        // takes priority over recording-cancel (only one of those flags
        // is ever true at a time, but explicit precedence is clearer).
        if type == .keyDown, shouldInterceptPolishKeys {
            if keyCode == kReturnKeyCode || keyCode == kKeypadEnterKeyCode {
                DispatchQueue.main.async { [weak self] in
                    self?.onPolishAccept?()
                }
                return nil
            }
            if keyCode == kEscapeKeyCode {
                DispatchQueue.main.async { [weak self] in
                    self?.onPolishCancel?()
                }
                return nil
            }
        }

        // --- keyDown: Escape cancels in-progress recording ---
        // Only intercepted when shouldInterceptEscape is true (Manager
        // toggles this around .recording) so regular Esc presses (close
        // sheet, unfocus field) still work when Voice Input isn't active.
        if type == .keyDown, keyCode == kEscapeKeyCode, shouldInterceptEscape {
            DispatchQueue.main.async { [weak self] in
                self?.onCancelPressed?()
            }
            return nil
        }

        // --- keyUp: clear space so a re-press within the same fn-hold
        // can fire polish again ---
        if type == .keyUp, keyCode == kSpaceKeyCode, fnIsDown {
            polishFiredThisFnHold = false
            return nil
        }

        // --- keyDown: track if another key pressed while fn or right Control held ---
        if type == .keyDown && fnIsDown {
            otherKeyDuringFn = true
        }
        if type == .keyDown && rightControlIsDown {
            otherKeyDuringRightControl = true
        }

        return Unmanaged.passUnretained(event)
    }
}
