import Foundation

/// Errors detected during progressive stream download (HTTP status, payload validation).
/// Surfaced to PlaybackService for user-facing error mapping.
enum ProgressiveStreamError: Error, LocalizedError {
    case httpError(statusCode: Int, bodySnippet: String?)
    case invalidPayload(bytesReceived: Int64)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let snippet):
            return "Server returned HTTP \(code)" + (snippet.map { ": \($0)" } ?? "")
        case .invalidPayload(let bytes):
            return "Server returned invalid audio data (\(bytes) bytes)"
        }
    }
}
