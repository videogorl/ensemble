import OSLog

/// Package-level logger for EnsembleAPI. Writes to the unified log and the
/// optional persistent session sink used for TestFlight diagnostics.
public enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "api")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    /// Parameters: (level, category, message)
    public static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "api"

    static func debug(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", category, msg)
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = message()
        logger.error("\(msg, privacy: .public)")
        fileLogHandler?("ERROR", category, msg)
    }
}
