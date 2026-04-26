// Abstract:
// Global hotkey monitor for voice input — intercepts the fn (Globe)
// key using CGEventTap to suppress the system emoji picker and
// toggle voice recording.
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
/// The Escape key's virtual key code — used by Voice Input to let the
/// user cancel an in-progress recording from anywhere, not just the ✕
/// on the overlay capsule.
private let kEscapeKeyCode: Int = 53

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

    @ObservationIgnored nonisolated(unsafe) var shouldInterceptEscape = false

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

        isMonitoring = true
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

    // MARK: - Event Handling

    /// Process a CGEventTap event. Returns nil to suppress, or the event to pass through.
    nonisolated func handleEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // --- flagsChanged: detect fn press/release ---
        if type == .flagsChanged {
            guard keyCode == kFnKeyCode else {
                return Unmanaged.passUnretained(event)
            }

            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let fnDown = flags.contains(.function)

            if fnDown && !fnIsDown {
                fnIsDown = true
                otherKeyDuringFn = false
                return nil
            } else if !fnDown && fnIsDown {
                fnIsDown = false
                let wasCleanTap = !otherKeyDuringFn
                otherKeyDuringFn = false

                if wasCleanTap {
                    DispatchQueue.main.async { [weak self] in
                        self?.onHotkeyPressed?()
                    }
                    return nil
                }
            }

            return Unmanaged.passUnretained(event)
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

        // --- keyDown: track if another key pressed while fn held ---
        if type == .keyDown && fnIsDown {
            otherKeyDuringFn = true
        }

        return Unmanaged.passUnretained(event)
    }
}
