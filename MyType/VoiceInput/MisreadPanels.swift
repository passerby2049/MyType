// Abstract:
// The two floating panels of the misread words (docs/design-misread-words.md
// 三): the small bar right of the pill, and the sheet above it. Both are
// non-activating, so the app in front never changes; the sheet can take the
// keyboard (selected) when clicked, and gives it back on esc, a click
// elsewhere, or 30 s without a take.

import AppKit
import SwiftUI

/// A panel that can take the keyboard without activating MyType; esc goes to `onEscape`. A press that
/// moves more than 3 pt drags the panel (from anywhere: the window's own drag doesn't start over glass);
/// one that doesn't is a click as usual.
final class MisreadKeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    private var press: (mouse: NSPoint, origin: NSPoint)?
    private var dragging = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where event.keyCode == 53:
            onEscape?()
            return
        case .leftMouseDown:
            press = (NSEvent.mouseLocation, frame.origin)
            dragging = false
        case .leftMouseDragged:
            if let press {
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - press.mouse.x, dy = mouse.y - press.mouse.y
                if dragging || hypot(dx, dy) > 3 {
                    dragging = true
                    setFrameOrigin(NSPoint(x: press.origin.x + dx, y: press.origin.y + dy))
                    return
                }
            }
        case .leftMouseUp:
            press = nil
            if dragging { dragging = false; return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MisreadPanels {
    static let sheetWidth: CGFloat = 520
    /// Around the glass, for its shadow and the selection glow.
    static let margin: CGFloat = 12

    /// Where the user dragged the sheet: its top-left corner, kept across sentences and launches.
    static let positionKey = "misreadSheetTopLeft"

    private(set) var bar: NSPanel?
    private(set) var sheet: MisreadKeyPanel?
    private var observers: [NSObjectProtocol] = []
    /// Set while the sheet is moved from here, so only a drag counts as the user's position.
    private var placing = false

    /// Called with true when the sheet takes the keyboard, false when it gives it back.
    var onSelection: ((Bool) -> Void)?
    var onEscape: (() -> Void)?

    func show(_ model: MisreadSheetModel, coach: MisreadCoach) {
        let bar = self.bar ?? makePanel(MisreadBarView(model: model, coach: coach), key: false)
        let sheet = self.sheet ?? makePanel(MisreadSheetView(model: model, coach: coach), key: true) as! MisreadKeyPanel
        (bar.contentView as? NSHostingView<MisreadBarView>)?.rootView = MisreadBarView(model: model, coach: coach)
        (sheet.contentView as? NSHostingView<MisreadSheetView>)?.rootView = MisreadSheetView(model: model, coach: coach)
        sheet.onEscape = { [weak self] in self?.onEscape?() }
        self.bar = bar
        self.sheet = sheet
        if observers.isEmpty { observe(sheet) }
        update(model)
    }

    /// Bring the panels in line with the model's phase, and resize to fit.
    func update(_ model: MisreadSheetModel) {
        guard let bar, let sheet else { return }
        place(bar: bar, sheet: sheet)
        switch model.phase {
        case .bar:
            fade(sheet, in: false)
            fade(bar, in: true)
        case .sheet:
            fade(bar, in: false)
            fade(sheet, in: true)
        }
    }

    func hide() {
        if let bar { fade(bar, in: false) }
        if let sheet { fade(sheet, in: false) }
    }

    /// Take the keyboard, as a click on the sheet does.
    func select() {
        sheet?.makeKey()
    }

    /// Give the keyboard back to the app in front: out and in again without becoming key.
    func deselect() {
        guard let sheet, sheet.isKeyWindow else { return }
        let alpha = sheet.alphaValue
        sheet.orderOut(nil)
        sheet.alphaValue = alpha
        sheet.orderFrontRegardless()
    }

    /// Resize after the content changed (a word left, a take added).
    func relayout() {
        guard let bar, let sheet else { return }
        place(bar: bar, sheet: sheet)
    }

    private func observe(_ sheet: NSPanel) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: sheet, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSelection?(true) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: sheet, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSelection?(false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: sheet, queue: .main) { [weak self, weak sheet] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing, let frame = sheet?.frame else { return }
                UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.positionKey)
            }
        })
    }

    private func fade(_ panel: NSPanel, in show: Bool) {
        panel.animations = [:]
        if show {
            guard !panel.isVisible || panel.alphaValue < 1 else { return }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        } else {
            guard panel.isVisible else { return }
            if panel.isKeyWindow { deselect() }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak panel] in
                if panel?.alphaValue == 0 { panel?.orderOut(nil) }
            })
        }
    }

    private func makePanel<V: View>(_ view: V, key: Bool) -> NSPanel {
        let panel: NSPanel = key ? MisreadKeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            : NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        // The glass is drawn by the window server: the window's own pixels there are clear, and a
        // click on clear pixels goes through to the window behind. Said outright, every click lands
        // here — so the sheet is selected, and dragged, by any part of it.
        panel.ignoresMouseEvents = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        return panel
    }

    /// The bar right of the pill's spot; the sheet centred above it (where the problem card goes).
    private func place(bar: NSPanel, sheet: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let pillMidY = frame.minY + 12 + 18
        if let host = bar.contentView {
            let size = host.fittingSize
            bar.setFrame(NSRect(x: frame.midX + VoiceInputPanel.contentSize.width / 2 - 4, y: pillMidY - size.height / 2,
                                width: size.width, height: size.height), display: true)
        }
        if let host = sheet.contentView {
            let size = host.fittingSize
            let pillTop = frame.minY + 12 + 36
            var rect = NSRect(x: frame.midX - size.width / 2, y: pillTop + 10 - Self.margin, width: size.width, height: size.height)
            // Where the user dragged it, if that's still on a screen: the top-left stays, it grows downwards.
            if let saved = UserDefaults.standard.string(forKey: Self.positionKey).map(NSPointFromString),
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(saved) }) {
                let visible = screen.visibleFrame.insetBy(dx: -Self.margin, dy: -Self.margin)
                rect.origin = NSPoint(x: min(max(saved.x, visible.minX), visible.maxX - size.width),
                                      y: max(saved.y - size.height, visible.minY))
            }
            placing = true
            sheet.setFrame(rect, display: true)
            placing = false
        }
    }
}
