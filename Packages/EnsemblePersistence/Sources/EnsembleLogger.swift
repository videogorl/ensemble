import OSLog

/// Package-level logger for EnsemblePersistence. Uses @autoclosure so message strings
/// are not constructed unless needed — zero cost when file logging is disabled in release.
public enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "persistence")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    /// Parameters: (level, category, message)
    public static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "persistence"

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
        #else
        guard let handler = fileLogHandler else { return }
        handler("DEBUG", category, message())
        #endif
    }
}
