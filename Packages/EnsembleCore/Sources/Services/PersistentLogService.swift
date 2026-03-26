import EnsembleAPI
import EnsemblePersistence
import Foundation
import OSLog

// MARK: - Log Session Model

/// Represents a single saved log session file on disk.
public struct LogSession: Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let fileURL: URL
    public let fileSize: Int64
}

// MARK: - PersistentLogService

#if !os(watchOS)

/// Manages persistent session logging by writing log entries to disk in real-time.
/// Each app session gets its own log file; the service keeps the last 5 sessions
/// and provides UI access for viewing, sharing, and deleting log files.
///
/// Thread-safe: logger callbacks fire from any thread; file writes serialize
/// on a private DispatchQueue. Force-quit safe: writes go through the OS write
/// buffer and are flushed periodically via synchronizeFile().
@MainActor
public final class PersistentLogService: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var sessions: [LogSession] = []

    // MARK: - Configuration

    /// Maximum number of session files to retain on disk.
    private static let maxSessions = 5

    /// How many writes between forced disk flushes (synchronizeFile).
    private static let flushInterval = 50

    /// UserDefaults key for the logging toggle.
    private static let enabledKey = "persistentLoggingEnabled"

    // MARK: - File Writer (thread-safe, owns file handle)

    /// Encapsulates all file I/O on a serial queue. This is the only
    /// object that touches the file handle, ensuring thread safety.
    private let writer = LogFileWriter()

    /// Date formatter for session file names.
    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Directory where session log files are stored.
    private static let logsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let logsDir = appSupport
            .appendingPathComponent("Ensemble", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir, withIntermediateDirectories: true
        )
        return logsDir
    }()

    // MARK: - Enabled State

    /// Whether persistent logging is enabled. Defaults to true.
    /// When disabled, handleLogEntry returns immediately without writing.
    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                writer.close()
            }
        }
    }

    // MARK: - Init

    public init() {
        // Register default so isEnabled returns true before first toggle
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        loadSessions()
    }

    // MARK: - Session Lifecycle

    /// Start a new logging session. Called once per app launch.
    /// Creates a new log file and writes a header with device/app info.
    public func startSession() {
        guard isEnabled else { return }

        let now = Date()
        let filename = "session-\(Self.filenameDateFormatter.string(from: now)).log"
        let fileURL = Self.logsDirectory.appendingPathComponent(filename)

        // Build session header
        let header = buildSessionHeader(startDate: now)

        writer.open(fileURL: fileURL, header: header)

        // Rotate old sessions (keep only the newest maxSessions)
        rotateSessions()
        loadSessions()
    }

    /// End the current session. Called when the app goes to background.
    /// Flushes and closes the file handle.
    public func endSession() {
        writer.close()
        loadSessions()
    }

    // MARK: - Session Management

    /// Scan the logs directory and populate the sessions list.
    public func loadSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.logsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            sessions = []
            return
        }

        let loaded = files
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> LogSession? in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int64 else {
                    return nil
                }
                let date = parseSessionDate(from: url.lastPathComponent)
                    ?? (attrs[.creationDate] as? Date ?? Date.distantPast)
                return LogSession(
                    id: UUID(), date: date,
                    fileURL: url, fileSize: size
                )
            }
            .sorted { $0.date > $1.date }

        if sessions.map(\.fileURL) != loaded.map(\.fileURL) {
            sessions = loaded
        }
    }

    /// Delete a specific session file.
    public func deleteSession(_ session: LogSession) {
        // If we're deleting the active session, close the handle first
        if session.fileURL == writer.currentURL {
            writer.close()
        }
        try? FileManager.default.removeItem(at: session.fileURL)
        loadSessions()
    }

    /// Delete all session files.
    public func deleteAllSessions() {
        writer.close()
        for session in sessions {
            try? FileManager.default.removeItem(at: session.fileURL)
        }
        loadSessions()
    }

    // MARK: - Handler Wiring

    /// Wire up log file handlers for all loggers reachable from EnsembleCore
    /// (API, Persistence, and Core). UI and App loggers are wired from the app target.
    public func installHandlers() {
        let handler = writer.makeHandler()

        // EnsembleCore's own logger
        EnsembleLogger.fileLogHandler = handler

        // EnsembleAPI logger (imported at top of file)
        EnsembleAPI.EnsembleLogger.fileLogHandler = handler

        // EnsemblePersistence logger (imported at top of file)
        EnsemblePersistence.EnsembleLogger.fileLogHandler = handler
    }

    /// Returns the log handler closure for external callers to wire
    /// loggers that EnsembleCore can't directly reach (UI, App).
    public var logHandler: (String, String, String) -> Void {
        writer.makeHandler()
    }

    // MARK: - Private Helpers

    /// Build the header block written at the top of each session file.
    private func buildSessionHeader(startDate: Date) -> String {
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")

        var header = "Ensemble Session Log\n"
        header += "Session start: \(displayFormatter.string(from: startDate))\n"
        header += "Device: \(deviceDescription())\n"
        header += "App version: \(appVersionString)\n"
        header += "---\n"
        return header
    }

    /// Remove old session files beyond the maxSessions limit.
    private func rotateSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.logsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        let logFiles = files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        // Keep only the newest maxSessions files
        if logFiles.count > Self.maxSessions {
            for file in logFiles.dropFirst(Self.maxSessions) {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Parse a session date from a filename like "session-2026-03-26-143000.log"
    private func parseSessionDate(from filename: String) -> Date? {
        let name = filename
            .replacingOccurrences(of: "session-", with: "")
            .replacingOccurrences(of: ".log", with: "")
        return Self.filenameDateFormatter.date(from: name)
    }

    /// App version string (e.g. "1.2.0 (42)")
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Human-readable device description for the session header.
    private func deviceDescription() -> String {
        #if os(iOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(machine) (iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion))"
        #elseif os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #else
        return "Unknown"
        #endif
    }
}

// MARK: - LogFileWriter (thread-safe file I/O)

/// Handles all file writing on a serial queue. Fully thread-safe and
/// callable from any thread without MainActor isolation.
private final class LogFileWriter: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.videogorl.ensemble.logwriter")
    private var fileHandle: FileHandle?
    private var writeCount = 0

    /// URL of the currently open log file (read on main for deletion checks).
    private(set) var currentURL: URL?

    /// Reusable timestamp formatter (only accessed on the serial queue).
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Open a new log file and write the session header.
    func open(fileURL: URL, header: String) {
        queue.sync {
            // Close any existing handle first
            fileHandle?.synchronizeFile()
            fileHandle?.closeFile()

            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: fileURL.path)
            currentURL = fileURL
            writeCount = 0

            if let data = header.data(using: .utf8) {
                fileHandle?.write(data)
            }
        }
    }

    /// Flush and close the current file handle.
    func close() {
        queue.sync {
            fileHandle?.synchronizeFile()
            fileHandle?.closeFile()
            fileHandle = nil
            currentURL = nil
            writeCount = 0
        }
    }

    /// Create a handler closure that can be assigned to EnsembleLogger.fileLogHandler.
    /// The closure is safe to call from any thread.
    func makeHandler() -> (String, String, String) -> Void {
        { [weak self] level, category, message in
            self?.write(level: level, category: category, message: message)
        }
    }

    /// Write a formatted log line to the current file. No-op if no file is open.
    private func write(level: String, category: String, message: String) {
        // Fast exit: check UserDefaults (thread-safe) before dispatching
        guard UserDefaults.standard.bool(forKey: "persistentLoggingEnabled") else { return }

        let timestamp = Date()

        queue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }

            let ts = self.timestampFormatter.string(from: timestamp)
            let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"

            guard let data = line.data(using: .utf8) else { return }
            handle.write(data)

            self.writeCount += 1
            if self.writeCount >= 50 {
                handle.synchronizeFile()
                self.writeCount = 0
            }
        }
    }
}

#else

// MARK: - watchOS Stub

/// No-op stub for watchOS where persistent logging is not supported.
@MainActor
public final class PersistentLogService: ObservableObject {
    @Published public private(set) var sessions: [LogSession] = []
    public var isEnabled: Bool {
        get { false }
        set { }
    }
    public init() {}
    public func startSession() {}
    public func endSession() {}
    public func loadSessions() {}
    public func deleteSession(_ session: LogSession) {}
    public func deleteAllSessions() {}
    public func installHandlers() {}
    public var logHandler: (String, String, String) -> Void { { _, _, _ in } }
}

#endif
