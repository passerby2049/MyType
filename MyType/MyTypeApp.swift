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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let statusMenuController = StatusMenuController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = Snapshot.directory {
            Snapshot.run(into: dir)
            return
        }
        setupMainMenu()
        setupStatusItem()
        VoiceInputManager.shared.activate()
        VoiceLog.shared.start()
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
            button.image = NSImage(named: "StatusBarIcon") ?? NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "MyType"
            )
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 16, height: 16)
            button.setAccessibilityLabel("MyType")
        }

        statusMenu.delegate = statusMenuController
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
        statusMenuController.statusItem = statusItem
        statusMenuController.watchRecordingState()
    }

    // MARK: - Windows

    @objc private func openSettings() { MainWindowController.shared.show(.settings) }
    @objc private func openHistory() { MainWindowController.shared.show(.history) }
    @objc private func openStats() { MainWindowController.shared.show(.stats) }
}

extension Notification.Name {
    static let openHistory = Notification.Name("MyType.openHistory")
}
