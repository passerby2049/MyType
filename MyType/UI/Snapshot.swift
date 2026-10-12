// Abstract:
// `MyType -snapshot <dir>` renders every page of the main window, light and
// dark, to PNGs and quits — how a change to the look is checked against the
// mockup (design/ui-redesign) without opening anything on screen. Nothing
// else starts in this mode: no hotkey, no model, no voice log.

import AppKit
import SwiftUI

@MainActor
enum Snapshot {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(into dir: String) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: MainView())
        window.orderFront(nil)

        let nav = MainNavigation.shared
        var shots: [(String, () -> Void)] = [
            ("history", { nav.page = .history }),
            ("stats", { nav.page = .stats }),
            ("vocabulary", { nav.page = .vocabulary }),
        ]
        for tab in SettingsTab.allCases {
            shots.append(("settings-\(tab.rawValue)", { nav.settingsTab = tab; nav.page = .settings }))
        }
        if let extra = Snapshot.menuShot { shots.append(("menu", extra)) }

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            for (name, select) in shots {
                select()
                settle(0.8)
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: url.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
        }
        NSApp.terminate(nil)
    }

    /// Set by the menu code to render its menu as a view, if it can.
    static var menuShot: (() -> Void)?

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
