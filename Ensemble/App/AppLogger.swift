import EnsembleSupport
import Foundation
import OSLog

/// App-target logger. Writes to the unified log and the optional persistent
/// session sink used for TestFlight diagnostics.
enum AppLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "app")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    static var fileLogHandler: EnsembleFileLogHandler?

    private static let category = "app"

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
