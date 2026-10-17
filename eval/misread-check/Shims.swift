// What the app's misread files need from the rest of the app, for misread-check: where the data goes.
import Foundation

enum VoiceInputStore {
    static let baseDirectory = FileManager.default.temporaryDirectory.appending(path: "misread-check-\(ProcessInfo.processInfo.processIdentifier)")
}
