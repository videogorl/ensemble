import Foundation

/// Correlates a single playback attempt across queue, transport, decode, render,
/// and completion so on-device logs can show where startup time is spent.
enum PlaybackJourneyLogger {
    private struct Journey {
        let id: String
        let startedAt: TimeInterval
    }

    private static let lock = NSLock()
    private static var activeJourneysByTrackId: [String: Journey] = [:]

    @discardableResult
    static func start(trackId: String, title: String, caller: String) -> String {
        let journey = Journey(
            id: UUID().uuidString.prefix(8).lowercased(),
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        lock.lock()
        activeJourneysByTrackId[trackId] = journey
        lock.unlock()
        log(event: "queueCommandReceived", trackId: trackId, journey: journey, detail: "caller=\(caller) title=\(title)")
        return journey.id
    }

    static func mark(_ event: String, trackId: String, detail: String? = nil) {
        guard let journey = journey(for: trackId) else {
            EnsembleLogger.playback("PLAYBACK_JOURNEY event=\(event) trackId=\(trackId) elapsedMs=-1")
            return
        }
        log(event: event, trackId: trackId, journey: journey, detail: detail)
    }

    static func finish(_ event: String, trackId: String, detail: String? = nil) {
        let journey: Journey?
        lock.lock()
        journey = activeJourneysByTrackId.removeValue(forKey: trackId)
        lock.unlock()
        guard let journey else {
            EnsembleLogger.playback("PLAYBACK_JOURNEY event=\(event) trackId=\(trackId) elapsedMs=-1")
            return
        }
        log(event: event, trackId: trackId, journey: journey, detail: detail)
    }

    private static func journey(for trackId: String) -> Journey? {
        lock.lock()
        defer { lock.unlock() }
        return activeJourneysByTrackId[trackId]
    }

    private static func log(event: String, trackId: String, journey: Journey, detail: String?) {
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - journey.startedAt) * 1_000)
        let safeDetail = detail
            .map { " detail=\($0.replacingOccurrences(of: "\n", with: " "))" }
            ?? ""
        EnsembleLogger.playback(
            "PLAYBACK_JOURNEY event=\(event) journey=\(journey.id) trackId=\(trackId) elapsedMs=\(elapsedMs)\(safeDetail)"
        )
    }
}
