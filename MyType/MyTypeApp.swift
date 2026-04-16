// Abstract:
// Menu bar voice input app. No dock icon — lives in the status bar.
// Uses NSApplication directly (not SwiftUI App lifecycle) for reliable
// menu bar app behavior — same pattern as TypeFlux.

import AppKit
import SwiftUI
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "MyTypeApp"
)

@main
struct MyTypeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        VoiceInputManager.shared.activate()
        NotificationCenter.default.addObserver(
            self, selector: #selector(openHistory),
            name: .openHistory, object: nil
        )
    }

    // MARK: - Main Menu (enables Cmd+C/V/X/A in text fields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MyType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "MyType"
            )
            button.image?.size = NSSize(width: 16, height: 16)
        }

        let menu = NSMenu()

        let titleItem = menu.addItem(
            withTitle: "MyType — Voice Input",
            action: nil, keyEquivalent: ""
        )
        titleItem.isEnabled = false

        menu.addItem(.separator())

        let settingsItem = menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

        let historyItem = menu.addItem(
            withTitle: "History…",
            action: #selector(openHistory),
            keyEquivalent: "h"
        )
        historyItem.target = self
        historyItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit MyType",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    // MARK: - Windows

    @objc private func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = VoiceInputSettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func openHistory() {
        logger.debug("openHistory called")
        if let w = historyWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = VoiceInputHistoryView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "history")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }
}

extension Notification.Name {
    static let openHistory = Notification.Name("MyType.openHistory")
}
