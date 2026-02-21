import OSLog

enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "core")

    static func debug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { String(describing: $0) }.joined(separator: separator)
        let suffix = terminator == "\n" ? "" : terminator
        logger.debug("\(message + suffix, privacy: .public)")
    }
}
