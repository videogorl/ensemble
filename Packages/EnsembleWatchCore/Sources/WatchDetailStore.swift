import CryptoKit
import EnsembleDomain
import Foundation

/// Small, source-scoped detail snapshots; an empty entry is a successful empty response.
actor WatchDetailStore {
    struct Entry: Codable {
        let key: String
        let fetchedAt: Date
        let tracks: [EnsembleTrack]

        var isFresh: Bool {
            let age = Date().timeIntervalSince(fetchedAt)
            return age >= 0 && age < 60
        }
    }

    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WatchDetails", isDirectory: true)) {
        self.directory = directory
    }

    static func key(source: String, kind: String, id: String) -> String {
        [source, kind, id].joined(separator: "\u{001F}")
    }

    func load(key: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.key == key else { return nil }
        return entry
    }

    func save(_ tracks: [EnsembleTrack], key: String) throws {
        try Task.checkCancellation()
        let entry = Entry(key: key, fetchedAt: Date(), tracks: tracks)
        let data = try JSONEncoder().encode(entry)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: key), options: .atomic)
        // ponytail: retain 32 recently fetched collections; use database membership if broad offline browsing is needed.
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        if files.count > 32 {
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(32) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func url(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
