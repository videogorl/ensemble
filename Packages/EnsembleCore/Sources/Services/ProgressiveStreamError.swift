import Foundation

/// Errors detected during progressive stream download (HTTP status, payload validation).
/// Surfaced to PlaybackService for user-facing error mapping.
enum ProgressiveStreamError: Error, LocalizedError {
    case httpError(statusCode: Int, bodySnippet: String?)
    case invalidPayload(bytesReceived: Int64)
    /// An original-quality file whose own media is damaged: the decoder rejected it, its bytes are
    /// not audio, or its audio ends far short of the length its container states. Never raised for
    /// a transcode, a network error, or an HTTP status. It alone starts the transcode fallback.
    case damagedOriginal(reason: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let snippet):
            return "Server returned HTTP \(code)" + (snippet.map { ": \($0)" } ?? "")
        case .invalidPayload(let bytes):
            return "Server returned invalid audio data (\(bytes) bytes)"
        case .damagedOriginal(let reason):
            return "The original file is damaged (\(reason))"
        }
    }
}
