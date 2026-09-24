import EnsembleSupport
import Foundation
import OSLog

/// Siri extension logger with the same privacy redaction policy as the app logger.
enum SiriExtensionLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble.siri-intents", category: "siri-extension")

    static func info(_ message: @autoclosure () -> String) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
    }
}
