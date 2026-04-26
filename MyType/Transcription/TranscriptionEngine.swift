// Abstract:
// Shared types for the speech-to-text path.

import Foundation

/// A single transcription result segment.
struct TranscriptionSegment {
    let text: AttributedString
    let isFinal: Bool
}

enum TranscriptionError: LocalizedError {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound

    var errorDescription: String? {
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
