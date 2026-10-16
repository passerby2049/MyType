// Abstract:
// The conversation the user is looking at while dictating into the
// Claude desktop app: the Code session on screen (ClaudeSessionLog.onScreen,
// checked against the window's web area through Accessibility) and its
// last exchange. The polish gets it, to recognise words already in the
// conversation; recognition doesn't (docs/design-misread-words.md 一、五).
// Other apps (terminals, Zed, Codex) have no context for now.

import AppKit
import ApplicationServices
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "ConversationContext"
)

enum ConversationContext {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    struct Context: Sendable {
        /// The Claude Code session id (the transcript's file name).
        let session: String
        let text: String
    }

    /// When recording into Claude starts: have its accessibility tree built
    /// and the session records parsed by the time it stops.
    static func prepare(pid: pid_t) {
        guard isClaude(pid) else { return }
        turnOnAccessibility(pid: pid)
        _ = ClaudeSessionLog.desktopSessions()
    }

    /// Ask Claude for its accessibility tree: Electron builds it only when
    /// asked (`AXManualAccessibility`). Once per Claude process.
    private static func turnOnAccessibility(pid: pid_t) {
        guard preparedPID.withLock({ $0 }) != pid else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            preparedPID.withLock { $0 = pid }
        }
    }

    /// The conversation on screen if the dictation goes into Claude's Code
    /// page and the session is certain; nil otherwise. Off the main thread:
    /// it reads files and asks Claude over Accessibility.
    static func read(pid: pid_t?) -> Context? {
        guard let pid, isClaude(pid) else { return nil }
        let started = Date()
        turnOnAccessibility(pid: pid)
        let webAreaTitle = codeWebAreaTitle(pid: pid)
        let sessions = ClaudeSessionLog.desktopSessions()
        guard let session = ClaudeSessionLog.onScreen(sessions, webAreaTitle: webAreaTitle) else {
            let newest = sessions.max { $0.lastFocusedAt < $1.lastFocusedAt }?.title ?? "-"
            logger.notice("No context: window \(webAreaTitle ?? "-", privacy: .public), last opened \(newest, privacy: .public) (\(ms(since: started)) ms)")
            return nil
        }
        guard let file = ClaudeSessionLog.transcriptFile(session: session.cliSessionId),
              let text = ClaudeSessionLog.lastExchange(in: file)?.text()
        else {
            logger.notice("No context: nothing to read in \(session.cliSessionId, privacy: .public) (\(ms(since: started)) ms)")
            return nil
        }
        logger.info("Context from \(session.title, privacy: .public): \(text.count) chars in \(ms(since: started)) ms")
        return Context(session: session.cliSessionId, text: text)
    }

    // MARK: - Accessibility

    private static let preparedPID = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
    /// A busy Claude answers in a few ms; don't let a stuck one hold the dictation.
    private static let axTimeout: Float = 0.1

    private static func isClaude(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == claudeBundleID
    }

    /// The title of the focused window's web area that shows a Code
    /// session ("<title> - Claude Code"). Measured 10/16: 11 nodes in, at
    /// depth 8, ~2 ms. Doesn't go into web areas (the page itself is
    /// hundreds of nodes).
    private static func codeWebAreaTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return nil
        }
        var queue: [(AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, axTimeout)
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                if let title = string(node, kAXTitleAttribute), title.hasSuffix(ClaudeSessionLog.webAreaTitleSuffix) {
                    return title
                }
                continue
            }
            guard depth < 14 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return nil
    }

    private static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)  // swiftlint:disable:this force_cast — type checked above
    }

    private static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
