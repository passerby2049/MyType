// Abstract:
// `MyType -misread-trial <dir>` (docs/design-misread-words.md 三「要先试的」):
// puts the misread bar and sheet on screen over a dark and a light wallpaper,
// a white and a black window, in light and dark, and screenshots each; then
// checks, on the real panels, that the app in front never changes and that
// the hotkey goes to practice only while the sheet is selected. Writes PNGs
// and checks.txt, and quits. Nothing else starts: no hotkey, no model.

import AppKit
import SwiftUI

@MainActor
enum MisreadTrial {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-misread-trial"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private enum Backdrop: String, CaseIterable {
        case darkWallpaper = "wallpaper-dark", lightWallpaper = "wallpaper-light", whiteWindow = "window-white", blackWindow = "window-black"
    }

    static func run(into dir: String) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let coach = MisreadCoach.shared
        coach.present(id: UUID(), raw: "The height of the two cars is not the same.", polished: "The height of the two cards is not the same.",
                      misreads: [VoiceMisread(word: "cards", heard: "cars", ipa: "/kɑrdz/", tip: "词尾 dz 没出来")])
        coach.model?.addTake(text: "The height of the two cars is not the same.", audio: nil)
        coach.model?.addTake(text: "the two cards", audio: nil)
        settle(0.6)
        if let i = CommandLine.arguments.firstIndex(of: "-misread-hold"), i + 1 < CommandLine.arguments.count {
            hold(coach, seconds: Double(CommandLine.arguments[i + 1]) ?? 20)
            return
        }

        let backdrop = makeBackdrop()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for kind in Backdrop.allCases {
                show(kind, in: backdrop)
                coach.expand()
                settle(0.9)
                capture(around: coach.panelFrames.sheet, to: url.appending(path: "sheet-\(kind.rawValue)-\(suffix).png"))
                do {
                    coach.selectForTrial()
                    settle(0.9)
                    capture(around: coach.panelFrames.sheet, to: url.appending(path: "sheet-selected-\(kind.rawValue)-\(suffix).png"))
                    coach.escape()
                }
                coach.collapse()
                settle(0.9)
                capture(around: coach.panelFrames.bar, to: url.appending(path: "bar-\(kind.rawValue)-\(suffix).png"))
            }
        }
        NSApp.appearance = nil
        backdrop.orderOut(nil)

        var checks = behaviour(coach)
        if let i = CommandLine.arguments.firstIndex(of: "-misread-practice-file"), i + 1 < CommandLine.arguments.count {
            // A recording recognized the way a take is: no vocabulary, no context, no polish.
            let file = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            var text: String?
            Task { @MainActor in text = (try? await VoiceInputManager.shared.transcribe(at: file, request: .practice)) ?? "(failed)" }
            let start = Date()
            while text == nil, Date().timeIntervalSince(start) < 120 { settle(0.1) }
            checks.append("practice recognition of \(file.lastPathComponent): \(text ?? "(timed out)")")
        }
        if let i = CommandLine.arguments.firstIndex(of: "-misread-timing"), i + 1 < CommandLine.arguments.count {
            checks += timing(coach, items: CommandLine.arguments[i + 1])
        }
        try? checks.joined(separator: "\n").write(to: url.appending(path: "checks.txt"), atomically: true, encoding: .utf8)
        print(checks.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    /// The front app across every move on the sheet, and the hotkey's route 20 times each way.
    private static func behaviour(_ coach: MisreadCoach) -> [String] {
        var out: [String] = []
        let front = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let before = front()
        var changed: [String] = []
        func step(_ name: String, _ action: () -> Void) {
            action()
            settle(0.4)
            if front() != before { changed.append(name) }
        }
        step("expand") { coach.expand() }
        step("select") { coach.selectForTrial() }
        step("speak") { coach.speak("cards", slow: false) }
        step("slow") { coach.speak("cards", slow: true) }
        step("tap word") { coach.wordTapped("cards") }
        step("escape") { coach.escape() }
        step("collapse") { coach.collapse() }
        step("expand again") { coach.expand() }
        out.append("front app unchanged: \(changed.isEmpty ? "yes" : "NO — changed at \(changed)") (pid \(before.map(String.init) ?? "nil"), \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        out.append("MyType active at the end: \(NSApp.isActive)")

        var wrong = 0
        for _ in 0..<20 {
            coach.selectForTrial()
            settle(0.15)
            if coach.route(dictationBusy: false) != .practice { wrong += 1 }
        }
        out.append("selected → practice: \(20 - wrong)/20 (wrong \(wrong))")
        wrong = 0
        for _ in 0..<20 {
            coach.selectForTrial()
            settle(0.1)
            coach.escape()
            settle(0.15)
            if coach.route(dictationBusy: false) != .dictation { wrong += 1 }
        }
        out.append("not selected → dictation: \(20 - wrong)/20 (wrong \(wrong))")
        coach.selectForTrial()
        settle(0.15)
        out.append("selected but a dictation under way → \(coach.route(dictationBusy: true))")
        out.append("practice recognition: \(RecognitionRequest.practice)")
        coach.done()
        return out
    }

    /// Typed → bar on screen with the real judge, over eval sentences that have candidates ({"raw", "polished",
    /// "context"} per line; fresh ids, so no record is touched). The session is warmed as a recording start would.
    private static func timing(_ coach: MisreadCoach, items path: String) -> [String] {
        struct Item: Decodable { let raw: String; let polished: String; let context: String? }
        let items = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
            .filter { $0.context != nil && !MisreadCandidates.candidates(raw: $0.raw, polished: $0.polished).isEmpty }
        coach.prepare(targetApp: "Claude")
        settle(8)
        var delays: [Double] = [], judged = 0
        for item in items {
            let id = UUID()
            coach.consider(id: id, raw: item.raw, polished: item.polished, conversation: item.context, typedAt: .now)
            let start = Date()
            // The judge answers; a sentence with a "sound" word puts up the bar.
            while Date().timeIntervalSince(start) < 20, coach.model?.recordID != id, MisreadJudge.lastFinished != id { settle(0.05) }
            judged += 1
            if coach.model?.recordID == id, let d = coach.lastDelay { delays.append(d) }
            coach.done()
            settle(0.3)
        }
        delays.sort()
        let p90 = delays.isEmpty ? 0 : delays[min(delays.count - 1, Int(Double(delays.count) * 0.9))]
        return ["timing: \(judged) sentences judged, \(delays.count) put up the bar; typed → bar median \(String(format: "%.2f", delays.isEmpty ? 0 : delays[delays.count / 2])) s, p90 \(String(format: "%.2f", p90)) s, max \(String(format: "%.2f", delays.last ?? 0)) s: \(delays.map { String(format: "%.1f", $0) })"]
    }

    /// The sheet left on screen for a while, for a hand (or a pointer tool) to drag: where it was, where it ended up,
    /// what was kept. The kept position is removed again, so the real app doesn't inherit it.
    private static func hold(_ coach: MisreadCoach, seconds: Double) {
        let quartz = { (r: CGRect) -> String in
            let h = NSScreen.screens.first?.frame.height ?? 0
            return "x \(Int(r.minX))…\(Int(r.maxX)), y \(Int(h - r.maxY))…\(Int(h - r.minY)) (top-left origin)"
        }
        let saved = UserDefaults.standard.string(forKey: MisreadPanels.positionKey)
        UserDefaults.standard.removeObject(forKey: MisreadPanels.positionKey)
        coach.expand()
        settle(0.5)
        print("sheet at \(quartz(coach.panelFrames.sheet))")
        fflush(stdout)
        var events: [String] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            events.append("\(event.type.rawValue)@\(event.window === NSApp.windows.first(where: { $0 is MisreadKeyPanel }) ? "sheet" : "other")")
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            events.append("\(event.type.rawValue)@elsewhere(window \(event.windowNumber))")
        }
        if CommandLine.arguments.contains("-misread-drag") {
            // A real drag through the HID stream: press in the header's empty middle, move 300 left and 250 up.
            let h = NSScreen.screens.first?.frame.height ?? 0
            let f = coach.panelFrames.sheet
            let start = CGPoint(x: f.midX, y: h - f.maxY + MisreadPanels.margin + 30)
            if CommandLine.arguments.contains("-misread-click-button") {
                // 「练完」, right of the header: it has pixels of its own.
                let button = CGPoint(x: f.maxX - MisreadPanels.margin - 16 - 72, y: start.y - 4)
                DispatchQueue.global().async {
                    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: button, mouseButton: .left)?.post(tap: .cghidEventTap)
                        usleep(40_000)
                    }
                }
                settle(0.8)
                print("clicked 练完 at \(Int(button.x)),\(Int(button.y)): sheet \(coach.model == nil ? "gone" : "still there")")
            }
            // Posted from another thread: the window's drag runs its own loop on this one.
            DispatchQueue.global().async {
                func send(_ type: CGEventType, _ p: CGPoint) {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(30_000)
                }
                send(.mouseMoved, start)
                send(.leftMouseDown, start)
                for i in 1...20 { send(.leftMouseDragged, CGPoint(x: start.x - CGFloat(i) * 15, y: start.y - CGFloat(i) * 12.5)) }
                send(.leftMouseUp, CGPoint(x: start.x - 300, y: start.y - 250))
            }
            settle(1.5)
            print("dragged from \(Int(start.x)),\(Int(start.y)) by -300,-250; Accessibility trusted: \(AXIsProcessTrusted()), may post events: \(CGPreflightPostEventAccess())")
        }
        settle(seconds)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let global { NSEvent.removeMonitor(global) }
        print("sheet window \(NSApp.windows.first(where: { $0 is MisreadKeyPanel })?.windowNumber ?? -1)")
        print("mouse events seen: \(events.count) \(events.prefix(4)) … \(events.suffix(2))")
        print("sheet now at \(quartz(coach.panelFrames.sheet)); kept \(UserDefaults.standard.string(forKey: MisreadPanels.positionKey) ?? "nothing")")
        coach.model?.addTake(text: "the log in the terminal", audio: nil)
        coach.relayoutForTrial()
        settle(0.5)
        print("after a take: \(quartz(coach.panelFrames.sheet))")
        if let saved { UserDefaults.standard.set(saved, forKey: MisreadPanels.positionKey) } else { UserDefaults.standard.removeObject(forKey: MisreadPanels.positionKey) }
        NSApp.terminate(nil)
    }

    private static func makeBackdrop() -> NSWindow {
        let frame = NSScreen.main?.frame ?? .zero
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.ignoresMouseEvents = true
        return window
    }

    private static func show(_ kind: Backdrop, in window: NSWindow) {
        let view: AnyView
        switch kind {
        case .darkWallpaper: view = AnyView(wallpaper("Big Sur Graphic Dark"))
        case .lightWallpaper: view = AnyView(wallpaper("Big Sur Graphic Light"))
        case .whiteWindow: view = AnyView(page(ground: .white, ink: .black))
        case .blackWindow: view = AnyView(page(ground: .black, ink: .white))
        }
        window.contentView = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.orderFrontRegardless()
    }

    private static func wallpaper(_ name: String) -> some View {
        let image = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/\(name).heic") ?? NSImage()
        return Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
    }

    /// A text window: lines of a chat, so the glass has something to show through.
    private static func page(ground: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<40, id: \.self) { i in
                Text(i % 3 == 0 ? "Fixed: the 7-day card is now at least 260 tall and grows with its content, so its top lines up with the today card."
                     : "The height of the two cards is not the same. 两张卡的高度不一样，看一下首页的布局。")
                    .font(.system(size: 15))
                    .foregroundStyle(ink.opacity(i % 3 == 0 ? 0.85 : 0.6))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ground)
    }

    /// A screenshot of the screen around `frame` (Cocoa coordinates), with 60 pt of what's behind.
    private static func capture(around frame: CGRect, to file: URL) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let r = frame.insetBy(dx: -60, dy: -60)
        let top = screen.frame.maxY - r.maxY
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(r.minX)),\(Int(top)),\(Int(r.width)),\(Int(r.height))", file.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// Wait, handing the app its events meanwhile (the trial runs inside launch, before NSApp's own loop).
    private static func settle(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }
}
