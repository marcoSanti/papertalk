// Why a speech server's audio couldn't be used, worded for the user.

import Foundation

extension SpeechAudio.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty: return L("The speech server sent no audio.")
        case .unreadable: return L("The speech server sent audio Papertalk can't read. Set it to return WAV.")
        case .compressedUnsupported: return L("The speech server sent compressed audio, which Papertalk can't read here. Set it to return WAV.")
        }
    }
}
