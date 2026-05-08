// Abstract:
// Reads the screen-space rect of the currently selected text in the
// focused UI element via the macOS Accessibility API. Used by the
// polish preview panel to anchor itself IME-style above the selection.
//
// Returns nil when the focused app doesn't expose selection bounds
// (some Electron apps, browser webviews, Java Swing, etc.). The
// caller is responsible for falling back to the mouse cursor or
// screen center.
//
// Note on coordinates: AX returns rects in *screen* coordinates with
// a TOP-LEFT origin (Quartz convention). NSWindow / NSScreen use
// BOTTOM-LEFT origin (Cocoa convention). Conversion is the caller's
// responsibility — done once at panel-positioning time.

import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "AXSelectionLocator"
)

enum AXSelectionLocator {

    /// Best-effort screen rect of the user's current text selection.
    /// Falls back to the focused element's frame if the selection rect
    /// isn't exposed. Returns nil if neither is available.
    static func selectionScreenRect() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()

        guard let focused = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else {
            logger.debug("No focused UI element")
            return nil
        }
        // swiftlint:disable:next force_cast — AX returns AXUIElement
        let focusedElement = focused as! AXUIElement

        if let rect = selectedRangeBoundsRect(focusedElement) {
            return rect
        }
        if let rect = elementFrameRect(focusedElement) {
            return rect
        }
        return nil
    }

    // MARK: - Selection Range Bounds

    /// Try the precise path: focused element's selected text range →
    /// screen bounds for that range. Works in well-behaved Cocoa apps.
    private static func selectedRangeBoundsRect(_ element: AXUIElement) -> CGRect? {
        guard let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute) else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        guard err == .success, let bounds = boundsValue else {
            return nil
        }
        // swiftlint:disable:next force_cast — AX value type
        let axValue = bounds as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect), !rect.isEmpty else {
            return nil
        }
        return rect
    }

    // MARK: - Element Frame Fallback

    /// Fallback path: just the focused element's overall frame in screen
    /// coords. Useful when an app exposes the focused text field but not
    /// the selection range bounds.
    private static func elementFrameRect(_ element: AXUIElement) -> CGRect? {
        guard let posValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue = copyAttribute(element, kAXSizeAttribute) else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        // swiftlint:enable force_cast
        let rect = CGRect(origin: pos, size: size)
        return rect.isEmpty ? nil : rect
    }

    // MARK: - Helper

    private static func copyAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return err == .success ? value : nil
    }
}
