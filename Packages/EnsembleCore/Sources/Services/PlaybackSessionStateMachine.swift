import Foundation

enum PlaybackSessionStateMachine {
    struct SessionRequest: Equatable {
        let generation: UInt64
        let track: Track
        let forcingFreshItem: Bool
        let recoverySeekTime: TimeInterval?
    }

    enum TerminalFailure: Equatable {
        case tls
        case connection(sourceCompositeKey: String?)
        case generic(message: String)
    }

    static let maxResolutionAttempts = 2
    static let retryableNetworkErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost,
    ]

    static func buildRequest(
        generation: UInt64,
        track: Track,
        forcingFreshItem: Bool,
        requestedSeekTime: TimeInterval?,
        effectiveTrackDuration: TimeInterval
    ) -> SessionRequest {
        SessionRequest(
            generation: generation,
            track: track,
            forcingFreshItem: forcingFreshItem,
            recoverySeekTime: validatedRecoverySeekTime(
                requestedSeekTime,
                effectiveTrackDuration: effectiveTrackDuration
            )
        )
    }

    static func shouldRetryResolution(after error: Error, attempt: Int) -> Bool {
        guard attempt + 1 < maxResolutionAttempts else { return false }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return retryableNetworkErrorCodes.contains(nsError.code)
    }

    static func isSuperseded(requestGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        requestGeneration != currentGeneration
    }

    static func classifyTerminalFailure(_ error: Error?, track: Track) -> TerminalFailure {
        guard let error else {
            return .generic(message: "Failed to load track")
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorSecureConnectionFailed {
            return .tls
        }
        if nsError.domain == NSURLErrorDomain && retryableNetworkErrorCodes.contains(nsError.code) {
            return .connection(sourceCompositeKey: track.sourceCompositeKey)
        }
        return .generic(message: error.localizedDescription)
    }

    static func validatedRecoverySeekTime(
        _ requestedTime: TimeInterval?,
        effectiveTrackDuration: TimeInterval
    ) -> TimeInterval? {
        guard let requestedTime else { return nil }
        guard requestedTime.isFinite else { return nil }
        guard requestedTime > 1 else { return nil }

        let upperBound = max(1, effectiveTrackDuration - 2)
        return min(requestedTime, upperBound)
    }
}
