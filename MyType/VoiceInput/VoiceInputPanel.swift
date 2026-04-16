// Abstract:
// Non-activating floating NSPanel that hosts the voice input capsule.
// Stays on top of all windows without stealing focus from the target app.

import AppKit
import SwiftUI

// MARK: - NSPanel Wrapper

final class VoiceInputPanel {
    private var panel: NSPanel?
    private weak var manager: VoiceInputManager?

    init(manager: VoiceInputManager) {
        self.manager = manager
    }

    @MainActor
    func showPanel() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Position the capsule near the bottom of whichever screen the
        // user is currently working on (the one containing the mouse),
        // not just NSScreen.main — matters in multi-monitor setups.
        // Hugs the dock the way Typeless does (~12pt clearance) so it
        // doesn't float in the middle of the screen.
        guard let screen = Self.activeScreen() else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 200
        let panelHeight: CGFloat = 80
        let x = screenFrame.midX - panelWidth / 2
        // visibleFrame already excludes the dock; add a small clearance
        // so the capsule sits just above it instead of touching.
        let bottomClearance: CGFloat = 12
        // The inner SwiftUI capsule (36pt high) isn't flush with the
        // panel's bottom edge — there's drop-shadow padding above and
        // below. Subtract half the panel padding so the visible pill
        // ends up at the requested clearance.
        let capsuleHeight: CGFloat = 36
        let y = screenFrame.minY + bottomClearance - (panelHeight - capsuleHeight) / 2

        panel.setFrame(
            NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            display: true
        )

        // Cancel any in-flight hide animation so a rapid
        // cancel → re-record doesn't get orderOut'd by the
        // old completion handler.
        panel.animations = [:]
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    @MainActor
    func hidePanel() {
        guard let panel else { return }
        let panelRef = panel
        panelRef.animations = [:]
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panelRef.animator().alphaValue = 0
        }, completionHandler: { [weak panelRef] in
            // Only order out if still invisible — a new showPanel
            // may have already brought it back.
            if panelRef?.alphaValue == 0 {
                panelRef?.orderOut(nil)
            }
        })
    }

    @MainActor
    func updateContent() {
        // SwiftUI binding handles updates automatically
        // via @Observable
    }

    /// The screen the user is currently working on — i.e. the one that
    /// contains the mouse cursor. Falls back to NSScreen.main, then to
    /// the first screen. Returns nil only when the app has no attached
    /// screens at all (vanishingly rare during normal lifecycle).
    @MainActor
    private static func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    @MainActor
    private func createPanel() {
        guard let manager else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Let AppKit draw the drop shadow based on the alpha mask of the
        // content (non-transparent pixels only). This gives a shadow that
        // tightly hugs the pill, with no rectangular clipping artifacts
        // — the same technique the Dictionary popup and notification
        // banners use.
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // Belt & braces: ensure the panel's own contentView doesn't
        // render any background of its own. Without this, the system
        // may paint a faint light rectangle behind the SwiftUI pill.
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        let hostingView = NSHostingView(
            rootView: VoiceInputOverlayView(manager: manager)
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.addSubview(hostingView)

        self.panel = panel
    }
}
