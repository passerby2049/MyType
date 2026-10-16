// Abstract:
// The conversation on screen for the polish (ConversationContext): read
// when recording stops, alongside recognition, and used only if it's
// ready when recognition is — it adds no wait.

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MyType",
    category: "VoiceInputManager"
)

extension VoiceInputManager {

    /// Start reading the conversation the dictation goes into.
    func readConversation() -> Task<ConversationContext.Context?, Never> {
        let pid = capturedTargetPID
        return Task.detached(priority: .userInitiated) { ConversationContext.read(pid: pid) }
    }

    /// The conversation, if it's read within 50 ms of recognition ending
    /// (it takes a few ms; recognition ~0.7 s). Otherwise the polish goes
    /// without it.
    func conversationIfReady(_ task: Task<ConversationContext.Context?, Never>) async -> ConversationContext.Context? {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (ConversationContext.Context?) -> Void = { context in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: context) }
            }
            Task { finish(await task.value) }
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                if !resumed.withLock({ $0 }) { logger.warning("Conversation not read in time — polishing without it") }
                finish(nil)
            }
        }
    }
}
