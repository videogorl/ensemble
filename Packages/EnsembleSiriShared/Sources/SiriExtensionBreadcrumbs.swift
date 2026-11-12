import Foundation

/// One step of the Siri extension's work, kept for the app's session log. The extension can only write to os_log,
/// which a session log never holds, so it leaves these in the App Group and the app logs them on its next activation.
/// Outcome codes and counts only: never a title, name or identifier.
public struct SiriExtensionBreadcrumb: Codable, Sendable, Equatable {
    public let at: Date
    public let event: String
    public let outcome: String
    public let counts: [String: Int]

    public init(at: Date = Date(), event: String, outcome: String, counts: [String: Int] = [:]) {
        self.at = at
        self.event = event
        self.outcome = outcome
        self.counts = counts
    }

    /// The line the app logs for this breadcrumb.
    public var logLine: String {
        let detail = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "SIRI_EXT_TRAIL at=\(ISO8601DateFormatter().string(from: at)) event=\(event) outcome=\(outcome)"
            + (detail.isEmpty ? "" : " \(detail)")
    }
}

/// A small bounded trail the extension appends to and the app drains.
public enum SiriExtensionBreadcrumbs {
    public static let filename = "siri-extension-breadcrumbs.json"
    public static let capacity = 40

    private static func url(appGroupIdentifier: String, fileManager: FileManager) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(filename)
    }

    /// Appends `breadcrumb`, dropping the oldest beyond `capacity`. Best effort: a failure never affects the request.
    public static func record(
        _ breadcrumb: SiriExtensionBreadcrumb,
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) {
        guard let url = url(appGroupIdentifier: appGroupIdentifier, fileManager: fileManager) else { return }
        record(breadcrumb, at: url)
    }

    static func record(_ breadcrumb: SiriExtensionBreadcrumb, at url: URL) {
        withLock(at: url) {
            var trail = read(at: url)
            trail.append(breadcrumb)
            if trail.count > capacity { trail.removeFirst(trail.count - capacity) }
            try? JSONEncoder().encode(trail).write(to: url, options: .atomic)
        }
    }

    /// The recorded trail, oldest first, removed from disk.
    public static func drain(
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        fileManager: FileManager = .default
    ) -> [SiriExtensionBreadcrumb] {
        guard let url = url(appGroupIdentifier: appGroupIdentifier, fileManager: fileManager) else { return [] }
        return drain(at: url)
    }

    static func drain(at url: URL) -> [SiriExtensionBreadcrumb] {
        withLock(at: url) {
            let trail = read(at: url)
            try? FileManager.default.removeItem(at: url)
            return trail
        } ?? []
    }

    /// Runs `body` holding an exclusive `flock` on a sibling lock file, so the extension's append and the app's drain
    /// never interleave across processes. The lock is never waited for (a suspended holder would stall Siri's reply or
    /// the app's activation): when it is held, or the lock file cannot be opened, `body` is skipped and nil returned.
    /// The trail is best effort; a skipped drain leaves the entries for the next one.
    private static func withLock<T>(at url: URL, _ body: () -> T) -> T? {
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private static func read(at url: URL) -> [SiriExtensionBreadcrumb] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SiriExtensionBreadcrumb].self, from: data)) ?? []
    }
}
