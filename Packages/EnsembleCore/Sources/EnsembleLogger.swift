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
