import OSLog

public enum EnsembleStartupTiming {
    /// Set by AppDelegate at launch for TTFMP measurement.
    /// Accessible from EnsembleCore without importing the app target.
    public static var launchTime: Date?

    /// Log time-to-first-meaningful-paint (once, then auto-disables)
    static var hasLoggedTTFMP = false
    public static func logTTFMP(milestone: String) {
        #if DEBUG
        guard !hasLoggedTTFMP, let launch = launchTime else { return }
        hasLoggedTTFMP = true
        let elapsed = Date().timeIntervalSince(launch)
        EnsembleLogger.debug("⏱️ TTFMP: \(milestone) at \(String(format: "%.2f", elapsed))s after launch")
        #endif
    }
}

enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "core")
    /// Separate logger for playback-critical events. Uses "playback" category so these
    /// can be filtered in Console.app with: `log stream --predicate 'category == "playback"'`
    private static let playbackLogger = Logger(subsystem: "com.videogorl.ensemble", category: "playback")

    /// Playback-critical log for device diagnostics. Logs at `.info` level so messages
    /// persist in the unified log (visible in Console.app after the fact, not just `log stream`).
    /// NOT behind `#if DEBUG` — these logs exist in Release builds for on-device triage.
    static func playback(_ message: String) {
        playbackLogger.info("\(message, privacy: .public)")
    }

    static func debug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { String(describing: $0) }.joined(separator: separator)
        let suffix = terminator == "\n" ? "" : terminator
        logger.debug("\(message + suffix, privacy: .public)")
    }

    static func info(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { String(describing: $0) }.joined(separator: separator)
        let suffix = terminator == "\n" ? "" : terminator
        logger.info("\(message + suffix, privacy: .public)")
    }

    static func error(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { String(describing: $0) }.joined(separator: separator)
        let suffix = terminator == "\n" ? "" : terminator
        logger.error("\(message + suffix, privacy: .public)")
    }
}
