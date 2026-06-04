import EnsembleSupport
import Foundation
import OSLog

/// App-target logger. Writes to the unified log and the optional persistent
/// session sink used for TestFlight diagnostics.
enum AppLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "app")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "app"

    static func debug(_ message: @autoclosure () -> String) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", category, msg)
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.error("\(msg, privacy: .public)")
        fileLogHandler?("ERROR", category, msg)
    }

    static func fault(_ message: @autoclosure () -> String) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.fault("\(msg, privacy: .public)")
        fileLogHandler?("FAULT", category, msg)
    }
}
