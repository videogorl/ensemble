import Foundation

/// Unified error taxonomy for Plex API errors.
/// Replaces duplicated classification logic in MutationCoordinator, PlexAPIClient,
/// and ConnectionFailoverManager with a single source of truth.
public enum PlexErrorClassification: Sendable {
    /// Transport/connectivity failure — safe to retry or queue for later.
    /// Includes: connection refused, timeout, DNS, network loss, TLS.
    case connectionFailure

    /// Server error (5xx) — server is up but struggling. Safe to retry later.
    case serverError

    /// Rate limited (429) — server is throttling requests. Safe to retry with backoff.
    case rateLimited

    /// Semantic/client error (4xx, auth, decode) — do not retry.
    /// Includes: bad request, unauthorized, not found, decode failures.
    case semanticError

    /// Request was cancelled — do not retry.
    case cancelled

    /// Whether this error class is safe to queue for retry.
    public var isRetryable: Bool {
        switch self {
        case .connectionFailure, .serverError, .rateLimited: return true
        case .semanticError, .cancelled: return false
        }
    }

    /// Whether this error class should trigger endpoint failover.
    public var shouldFailover: Bool {
        self == .connectionFailure
    }

    /// Whether this error is a 429 rate-limit response.
    public var isRateLimited: Bool {
        self == .rateLimited
    }

    /// Classify an arbitrary Error into one of the four categories.
    public static func classify(_ error: Error) -> PlexErrorClassification {
        if error is CancellationError {
            return .cancelled
        }

        // PlexAPIError wrappers
        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .networkError(let underlying):
                return classify(underlying)
            case .invalidResponse:
                return .connectionFailure
            case .httpError(let statusCode):
                if statusCode == 429 {
                    return .rateLimited
                }
                if (500...599).contains(statusCode) {
                    return .serverError
                }
                return .semanticError
            case .decodingError, .invalidURL, .notAuthenticated, .noServerSelected:
                return .semanticError
            }
        }

        // URLSession transport errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .dataNotAllowed,
                 .internationalRoamingOff:
                return .connectionFailure
            default:
                return .semanticError
            }
        }

        // NSURLError domain fallback (some errors arrive as NSError)
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled {
                return .cancelled
            }
            if nsError.code == NSURLErrorSecureConnectionFailed {
                return .connectionFailure
            }
        }

        // Unknown errors default to semantic (don't retry blindly)
        return .semanticError
    }
}
