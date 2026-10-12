// Abstract:
// Polish flow — fn+space hotkey takes the user's currently selected
// text from any app, runs it through the LLM polisher, and (after
// preview-confirm) writes the cleaned-up version back over the
// selection.
//
// UI: the polish preview panel shows above the selection IME-style.
// Loading state appears immediately after fn+space; once the LLM
// returns the panel transitions to content state. The user accepts
// with ⏎ or cancels with ⎋ — both keys are intercepted by
// GlobalHotkeyMonitor while the preview is up so they don't leak
// into the focused app (Slack would send, Cursor would commit, etc.).
//
// Clipboard: the user's pasteboard is snapshotted (string only),
// briefly overwritten with the polished text for the synthetic Cmd+V,
// then restored.

import AppKit
import CoreGraphics
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

private let kCKeyCode: CGKeyCode = 8
private let kVKeyCode: CGKeyCode = 9

/// Result of one polish session.
private enum PolishOutcome {
    case accept(String)
    case cancel
    case noChanges
    case error
}

/// Coordinates the lifecycle of one polish invocation. Owns the
/// continuation that the manager awaits, plus the LLM task so a user
/// cancel during loading can interrupt it.
@MainActor
private final class PolishSession {
    private var continuation: CheckedContinuation<PolishOutcome, Never>?
    var llmTask: Task<Void, Never>?
    var polishedText: String?
    /// Set when the user pressed ⏎ before the LLM returned. We honor
    /// the intent and auto-accept once the polish lands.
    private var queuedAccept = false

    func awaitOutcome() async -> PolishOutcome {
        await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }

    func userAccepted() {
        if let polished = polishedText {
            finish(.accept(polished))
        } else {
            queuedAccept = true
        }
    }

    func userCancelled() {
        llmTask?.cancel()
        finish(.cancel)
    }

    func llmCompleted(_ text: String, original: String) {
        polishedText = text
        if text == original {
            finish(.noChanges)
        } else if queuedAccept {
            finish(.accept(text))
        }
        // Else: keep panel open, wait for user.
    }

    func llmFailed() {
        finish(.error)
    }

    private func finish(_ outcome: PolishOutcome) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: outcome)
    }
}

extension VoiceInputManager {

    // MARK: - Public Entry

    /// Triggered by fn+space — grab the user's selected text, polish it
    /// via the configured LLM, show the preview panel, and (on accept)
    /// overwrite the selection with the polished text. No-op if the
    /// manager is busy with a voice recording or already processing.
    func polishSelectedText() {
        switch state {
        case .recording, .transcribing, .polishing, .inserting:
            logger.info("Polish ignored — busy with state \(String(describing: self.state))")
            return
        case .idle, .done, .failure:
            break
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        capturedTargetPID = frontApp?.processIdentifier
        capturedTargetName = frontApp?.localizedName
        // Mouse position is the fallback anchor when AX selection lookup
        // fails (some Electron / browser cases). Capture it now while
        // the user's hand is still on the spot they care about.
        let mouseFallback = NSEvent.mouseLocation
        logger.info("Polish target: \(self.capturedTargetName ?? "unknown") (pid=\(self.capturedTargetPID ?? -1))")

        processingTask?.cancel()
        processingTask = Task { @MainActor [weak self] in
            await self?.runPolishFlow(mouseFallback: mouseFallback)
        }
    }

    // MARK: - Flow

    private func runPolishFlow(mouseFallback: NSPoint) async {
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        let originalChangeCount = pasteboard.changeCount

        postModifierShortcut(keyCode: kCKeyCode)
        try? await Task.sleep(for: .milliseconds(120))

        guard pasteboard.changeCount > originalChangeCount,
              let selectedText = pasteboard.string(forType: .string),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            logger.info("Polish: no text selected — silent dismiss")
            if pasteboard.changeCount != originalChangeCount {
                restoreClipboard(savedClipboard, pasteboard: pasteboard,
                                  ifStillAt: pasteboard.changeCount)
            }
            return
        }
        // The pasteboard now holds the selection we copied. Put the user's
        // own back at the end only if it still holds that — a copy the user
        // made meanwhile stays.
        let copiedChangeCount = pasteboard.changeCount

        let anchorAXRect = AXSelectionLocator.selectionScreenRect()
            ?? mouseAXRect(mouseFallback)

        let session = PolishSession()

        PolishPreviewPanel.shared.showLoading(anchorAXRect: anchorAXRect)
        // Wire ⏎/⎋ from CGEventTap directly to the session. The panel
        // doesn't own the keys — it has no buttons by design — so this
        // is the only path from key press to outcome.
        hotkeyMonitor.onPolishAccept = { [weak session] in
            Task { @MainActor in session?.userAccepted() }
        }
        hotkeyMonitor.onPolishCancel = { [weak session] in
            Task { @MainActor in session?.userCancelled() }
        }
        hotkeyMonitor.shouldInterceptPolishKeys = true

        // Run polish concurrently with awaiting user choice. The session
        // owns the continuation; either the LLM result or a user key
        // press resolves it.
        session.llmTask = Task { @MainActor [weak session] in
            do {
                let polished = try await TextPolisher.polish(
                    selectedText,
                    frontApp: capturedTargetName
                )
                try Task.checkCancellation()
                guard let session else { return }
                session.llmCompleted(polished, original: selectedText)
                if polished != selectedText {
                    let freshAnchor = AXSelectionLocator.selectionScreenRect() ?? anchorAXRect
                    PolishPreviewPanel.shared.showContent(polished, anchorAXRect: freshAnchor)
                }
            } catch is CancellationError {
                // User cancelled during loading — outcome already set.
            } catch {
                logger.error("Polish failed: \(error.localizedDescription, privacy: .public)")
                session?.llmFailed()
            }
        }

        let outcome = await session.awaitOutcome()

        hotkeyMonitor.shouldInterceptPolishKeys = false
        hotkeyMonitor.onPolishAccept = nil
        hotkeyMonitor.onPolishCancel = nil
        PolishPreviewPanel.shared.dismiss()

        switch outcome {
        case .accept(let polished):
            await pasteAndRestore(
                polished: polished,
                savedClipboard: savedClipboard,
                pasteboard: pasteboard
            )
            logger.info("Polish accepted (\(selectedText.count) → \(polished.count) chars)")

        case .cancel:
            restoreClipboard(savedClipboard, pasteboard: pasteboard,
                              ifStillAt: copiedChangeCount)
            logger.info("Polish cancelled")

        case .noChanges:
            restoreClipboard(savedClipboard, pasteboard: pasteboard,
                              ifStillAt: copiedChangeCount)
            logger.info("Polish: no changes from LLM — dismissed")

        case .error:
            restoreClipboard(savedClipboard, pasteboard: pasteboard,
                              ifStillAt: copiedChangeCount)
            if soundEffectsEnabled {
                errorSound?.play()
            }
        }
    }

    /// Build a 1×1 AX-coord rect at the mouse cursor location. AX uses
    /// a top-left origin; NSEvent.mouseLocation is bottom-left.
    private func mouseAXRect(_ mouseLocation: NSPoint) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: mouseLocation.x - 1,
            y: primaryHeight - mouseLocation.y - 1,
            width: 2,
            height: 2
        )
    }

    // MARK: - Paste & Clipboard Restore

    private func pasteAndRestore(
        polished: String,
        savedClipboard: String?,
        pasteboard: NSPasteboard
    ) async {
        pasteboard.clearContents()
        pasteboard.setString(polished, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        if let pid = capturedTargetPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            try? await Task.sleep(for: .milliseconds(80))
        }

        postModifierShortcut(keyCode: kVKeyCode)

        // Wait for the target app to read the pasteboard before we
        // overwrite it. Most native Cocoa apps read on Cmd+V; Electron
        // renderers can take ~150ms, longer when busy — nothing is waiting
        // on this, so give them room.
        try? await Task.sleep(for: .milliseconds(500))

        restoreClipboard(savedClipboard, pasteboard: pasteboard,
                          ifStillAt: ourChangeCount)
    }

    /// Put the user's clipboard back, only if the pasteboard is still at
    /// `changeCount` — what we (or our Cmd+C) left there. Was a test for
    /// "changed since", which the cancel / no-change / error paths passed
    /// the current count to, so it never restored: the user's clipboard
    /// was left holding the selection.
    private func restoreClipboard(
        _ saved: String?,
        pasteboard: NSPasteboard,
        ifStillAt changeCount: Int
    ) {
        if pasteboard.changeCount == changeCount {
            pasteboard.clearContents()
            if let saved {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    // MARK: - Synthetic shortcut

    private func postModifierShortcut(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Clear any held modifiers (the user may still be holding fn at
        // this point) so the synthetic Cmd is the only flag the target
        // sees.
        if let flagsClear = CGEvent(source: source) {
            flagsClear.type = .flagsChanged
            flagsClear.flags = []
            flagsClear.post(tap: .cghidEventTap)
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
