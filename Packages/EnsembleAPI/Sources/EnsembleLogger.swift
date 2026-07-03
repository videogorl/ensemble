import EnsembleSupport
import OSLog

/// Package-level logger for EnsembleAPI. Writes to the unified log and the
/// optional persistent session sink used for TestFlight diagnostics.
public enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "api")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    /// Parameters: (level, category, message)
    public static var fileLogHandler: EnsembleFileLogHandler?

    private static let category = "api"

    static func debug(_ message: @autoclosure () -> String) {
        EnsembleLogEmitter.debug(message(), logger: logger, category: category, fileLogHandler: fileLogHandler)
    }

    static func info(_ message: @autoclosure () -> String) {
        EnsembleLogEmitter.info(message(), logger: logger, category: category, fileLogHandler: fileLogHandler)
    }

    static func error(_ message: @autoclosure () -> String) {
        EnsembleLogEmitter.error(message(), logger: logger, category: category, fileLogHandler: fileLogHandler)
    }
}
