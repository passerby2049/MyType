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
        // The overlay's cards and the polish preview, on a desktop-like ground.
        let samples: [ProblemCard.Problem] = [.copied, .polishTimeout, .polishArrived("x"), .insertFailed("x"), .noSpeech]
        let preview = PolishPreviewViewModel()
        preview.state = .content("特别是 hotkey monitor 里关于 fn 键状态恢复的部分，有没有漏掉的情况？",
                                 original: "特别是那个 hotkey monitor 里面关于 fn 键状态恢复的部分有没有漏掉的情况",
                                 footnote: "Claude Sonnet · 1.6 秒")
        let scene = VStack(spacing: 14) {
            PolishPreviewView(model: preview)
            ForEach(samples.indices, id: \.self) { i in
                let model = ProblemCardModel()
                let _ = { model.problem = samples[i] }()
                ProblemCardView(model: model, hover: { _ in })
            }
        }
        .padding(40)
        .frame(width: 980, height: 660)
        .background(LinearGradient(colors: [Color(red: 0.79, green: 0.84, blue: 0.89), Color(red: 0.85, green: 0.81, blue: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
        window.contentView = NSHostingView(rootView: scene)
        settle(0.8)
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("overlay-cards.png"))
        }

        // The menu bar menu, as text.
        let menu = NSMenu()
        let controller = StatusMenuController()
        controller.menuNeedsUpdate(menu)
        let lines = menu.items.map { item -> String in
            if item.isSeparatorItem { return "———" }
            let title = item.attributedTitle?.string ?? item.title
            let key = item.keyEquivalent.isEmpty ? "" : "   [\(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")\(item.keyEquivalentModifierMask.contains(.option) ? "⌥" : "")⌘?\(item.keyEquivalent)]"
            return (item.isAlternate ? "  (⌥) " : "") + title.replacingOccurrences(of: "\n", with: " / ") + key + (item.state == .on ? "  ✓" : "")
        }
        try? lines.joined(separator: "\n").write(to: url.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
