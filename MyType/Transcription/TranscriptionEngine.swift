// Abstract:
// Transcription engine protocol and engine registry.
// All speech-to-text backends conform to this protocol.

import AVFoundation
import Foundation

// MARK: - Transcription Result

/// A single transcription result segment with optional timing.
struct TranscriptionSegment {
    let text: AttributedString
    let isFinal: Bool
    /// Optional timing for subtitle card generation (seconds).
    var startTime: Double?
    var endTime: Double?
    /// Raw per-token timings for the entire file (FluidAudio only).
    /// Carried on the first yielded segment so the caller can persist them.
    var rawTokenTimings: [RawTokenTiming]?
}

// MARK: - Transcription Engine Protocol

/// Unified interface for all speech-to-text backends.
///
/// Engines receive an audio file URL and deliver results via an AsyncStream.
/// The stream emits partial (volatile) results and final results, matching
/// the existing SpokenWordTranscriber consumption pattern.
protocol TranscriptionEngine {
    /// Human-readable name for display in settings.
    var displayName: String { get }

    /// Unique identifier for persistence.
    var id: String { get }

    /// Whether this engine is available on the current system.
    var isAvailable: Bool { get }

    /// Prepare the engine (download models if needed).
    /// - Parameter progressHandler: Optional callback for
    ///   download progress (0.0 - 1.0).
    func prepare(
        locale: Locale,
        progressHandler: ((Double) -> Void)?
    ) async throws

    /// Transcribe an audio file, returning an async stream of
    /// segments. The stream should emit volatile (partial)
    /// results followed by final results.
    func transcribe(
        audioFileURL: URL,
        locale: Locale
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

// MARK: - Transcription Errors

public enum TranscriptionError: LocalizedError {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound

    public var errorDescription: String? {
        switch self {
        case .couldNotDownloadModel:
            return "Could not download the model."
        case .failedToSetupRecognitionStream:
            return "Could not set up the speech "
                + "recognition stream."
        case .invalidAudioDataType:
            return "Unsupported audio format."
        case .localeNotSupported:
            return "This locale is not yet supported "
                + "by SpeechAnalyzer."
        case .noInternetForModelDownload:
            return "The model could not be downloaded "
                + "because the user is not connected "
                + "to internet."
        case .audioFilePathNotFound:
            return "Couldn't find the audio file."
        }
    }
}
