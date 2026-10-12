// Abstract:
// Non-activating, IME-style floating panel for the polish preview.
// Anchors above (or below, when no room) the user's text selection
// using AX-derived screen rects, with sensible fallbacks.
//
// Visuals: the panel itself is a fully transparent borderless shell.
// All material / shadow / corner-radius lives in the SwiftUI content
// layer via `.glassEffect` (Liquid Glass on macOS 26+), matching the
// pattern used by Jot's HUDWindow.
//
// Sizing: the panel resizes to whatever the SwiftUI view reports as
// its fitting size. Short polished text → narrow card. Long text →
// caps at the SwiftUI view's maxWidth and wraps to multiple lines.

import AppKit
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "PolishPreviewPanel"
)

/// NSPanel subclass matching Jot's HUDWindow recipe — borderless +
/// fullSizeContentView + floating-panel + transparent — which is the
/// shape `.glassEffect` actually renders into. We additionally prevent
/// the panel from ever becoming key so fn+space doesn't yank the user
/// out of a fullscreen app's space.
private final class PolishPreviewWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // becomesKeyOnlyIfNeeded = true means the panel doesn't grab key
        // status when ordered front; it only becomes key when a control
        // inside it needs focus (e.g., user clicks the text to select).
        // That gives us text selection + Cmd+C without the panel stealing
        // focus on appearance.
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
    }

    // Allow becoming key so SwiftUI's .textSelection works (user can
    // drag-select polished text and Cmd+C). Combined with
    // becomesKeyOnlyIfNeeded = true above, the panel only takes key
    // status on explicit user interaction, not on appearance.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PolishPreviewPanel {
    static let shared = PolishPreviewPanel()

    let model = PolishPreviewViewModel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<PolishPreviewView>?

    /// AX rect from the most recent show; cached so a state transition
    /// (loading → content) can re-anchor without another AX query.
    private var lastAnchorAXRect: CGRect?

    /// Width budget passed to the hosting view during measurement. The
    /// SwiftUI view enforces its own maxWidth internally, but we need a
    /// generous outer bound so its `frame(maxWidth:)` activates.
    private let measurementWidth: CGFloat = 600
    /// Gap between the card and the selection rect.
    private let selectionGap: CGFloat = 8

    // MARK: - Public API

    func showLoading(anchorAXRect: CGRect?) {
        let panel = ensurePanel()
        lastAnchorAXRect = anchorAXRect
        model.state = .loading
        let size = measureCardSize()
        applyFrame(panel, contentSize: size, anchorAXRect: anchorAXRect)
        animateIn(panel)
    }

    func showContent(_ text: String, original: String, footnote: String, anchorAXRect: CGRect?) {
        guard let panel else { return }
        if let r = anchorAXRect { lastAnchorAXRect = r }
        model.state = .content(text, original: original, footnote: footnote)

        // Defer measurement so SwiftUI applies the new state before we
        // ask for its fitting size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let size = self.measureCardSize()
            self.applyFrame(
                panel,
                contentSize: size,
                anchorAXRect: self.lastAnchorAXRect,
                animate: true
            )
        }
    }

    func dismiss() {
        guard let panel else { return }
        animateOut(panel)
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let p = PolishPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48))

        let host = NSHostingView(rootView: PolishPreviewView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 48)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        panel = p
        hostingView = host
        return p
    }

    // MARK: - Sizing

    /// Ask the SwiftUI hosting view what size it wants. Width-constrain
    /// the host first so SwiftUI's `frame(maxWidth:)` can engage; the
    /// returned fittingSize is the natural size for the current state.
    private func measureCardSize() -> NSSize {
        guard let host = hostingView else { return NSSize(width: 200, height: 48) }
        host.frame = NSRect(x: 0, y: 0, width: measurementWidth, height: 10_000)
        host.layoutSubtreeIfNeeded()
        let s = host.fittingSize
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    // MARK: - Positioning

    private func applyFrame(
        _ panel: NSPanel,
        contentSize: CGSize,
        anchorAXRect: CGRect?,
        animate: Bool = false
    ) {
        let frame = computeFrame(contentSize: contentSize, anchorAXRect: anchorAXRect)
        panel.setFrame(frame, display: true, animate: animate)
    }

    private func computeFrame(
        contentSize: CGSize,
        anchorAXRect: CGRect?
    ) -> NSRect {
        let screen = activeScreen()
        let screenFrame = screen.frame

        let cardW = contentSize.width
        let cardH = contentSize.height

        var x = screenFrame.midX - cardW / 2
        var y = screenFrame.midY - cardH / 2

        if let axRect = anchorAXRect, !axRect.isEmpty,
           let nsSelection = nsRect(fromAXRect: axRect) {
            x = nsSelection.midX - cardW / 2
            let candidateY = nsSelection.maxY + selectionGap
            if candidateY + cardH > screenFrame.maxY - 4 {
                y = nsSelection.minY - selectionGap - cardH
            } else {
                y = candidateY
            }
        }

        let inset: CGFloat = 8
        x = max(screenFrame.minX + inset, min(x, screenFrame.maxX - cardW - inset))
        y = max(screenFrame.minY + inset, min(y, screenFrame.maxY - cardH - inset))

        return NSRect(x: x, y: y, width: cardW, height: cardH)
    }

    private func nsRect(fromAXRect axRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        return NSRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    // MARK: - Show / Hide animation

    private func animateIn(_ panel: NSPanel) {
        panel.animations = [:]
        if !panel.isVisible || panel.alphaValue < 0.99 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    private func animateOut(_ panel: NSPanel) {
        panel.animations = [:]
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            panelRef.animator().alphaValue = 0
        }, completionHandler: { [weak panelRef] in
            if panelRef?.alphaValue == 0 {
                panelRef?.orderOut(nil)
            }
        })
    }
}
