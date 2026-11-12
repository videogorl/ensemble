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
        var trail = read(at: url)
        trail.append(breadcrumb)
        if trail.count > capacity { trail.removeFirst(trail.count - capacity) }
        try? JSONEncoder().encode(trail).write(to: url, options: .atomic)
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
        let trail = read(at: url)
        try? FileManager.default.removeItem(at: url)
        return trail
    }

    private static func read(at url: URL) -> [SiriExtensionBreadcrumb] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SiriExtensionBreadcrumb].self, from: data)) ?? []
    }
}
