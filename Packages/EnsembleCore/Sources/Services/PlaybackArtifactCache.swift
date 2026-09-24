import AVFoundation
import Foundation

enum PlaybackArtifactDelivery: String, Codable, Sendable {
    case direct
    case transcode
}

struct PlaybackArtifactKey: Codable, Equatable, Sendable {
    let trackIdentity: String
    let sourceFingerprint: String
    let requestedQuality: String
    let delivery: PlaybackArtifactDelivery
    let fileExtension: String
    let startTime: TimeInterval

    var isCompleteTrack: Bool { startTime == 0 }

    static func sourceFingerprint(for track: Track) -> String {
        let modified = track.dateModified.map { String($0.timeIntervalSince1970) } ?? "unknown"
        return "\(track.streamKey ?? track.key)|\(modified)|\(track.duration)"
    }
}

struct PlaybackArtifactManifest: Codable, Equatable, Sendable {
    let key: PlaybackArtifactKey
    let fileName: String
    let byteCount: Int64
    let expectedDuration: TimeInterval?
    let completedAt: Date
    var lastAccessedAt: Date
}

/// Persistent, purgeable playback artifacts. Download records and files remain
/// owned by OfflineDownloadService and DownloadManager.
final class PlaybackArtifactCache: @unchecked Sendable {
    static let shared = PlaybackArtifactCache()
    static let defaultByteBudget: Int64 = 1_073_741_824
    private static let fileLock = NSLock()
    static let didChange = Notification.Name("PlaybackArtifactCacheDidChange")

    let directory: URL
    let byteBudget: Int64
    private let fileManager: FileManager
    private var cachedManifests: [String: PlaybackArtifactManifest]?

    init(
        directory: URL = PlaybackStreamCacheIdentity.streamCacheDirectory,
        byteBudget: Int64 = PlaybackArtifactCache.defaultByteBudget,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.byteBudget = max(0, byteBudget)
        self.fileManager = fileManager
    }

    func partialURL(for key: PlaybackArtifactKey) throws -> URL {
        try ensureDirectory()
        return directory.appendingPathComponent(
            PlaybackStreamCacheIdentity.fileName(
                for: key.trackIdentity,
                suffix: "partial-\(UUID().uuidString)",
                pathExtension: key.fileExtension
            )
        )
    }

    func completedArtifact(
        trackIdentity: String,
        sourceFingerprint: String,
        requestedQuality: String,
        requireDirect: Bool
    ) -> URL? {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard let manifests = loadValidManifestsLocked() else { return nil }

        guard var match = manifests
            .filter({ manifest in
                manifest.key.trackIdentity == trackIdentity
                    && manifest.key.sourceFingerprint == sourceFingerprint
                    && manifest.key.requestedQuality == requestedQuality
                    && manifest.key.isCompleteTrack
                    && (!requireDirect || manifest.key.delivery == .direct)
            })
            .max(by: { $0.lastAccessedAt < $1.lastAccessedAt })
        else { return nil }

        let fileURL = directory.appendingPathComponent(match.fileName)
        guard (try? fileSize(at: fileURL)) == match.byteCount else {
            removeArtifactLocked(fileURL: fileURL)
            return nil
        }
        match.lastAccessedAt = Date()
        try? writeManifestLocked(match)
        return fileURL
    }

    func hasCompletedArtifact(
        trackIdentity: String,
        sourceFingerprint: String,
        requestedQuality: String,
        requireDirect: Bool
    ) -> Bool {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard let match = loadValidManifestsLocked()?.first(where: { manifest in
            manifest.key.trackIdentity == trackIdentity
                && manifest.key.sourceFingerprint == sourceFingerprint
                && manifest.key.requestedQuality == requestedQuality
                && manifest.key.isCompleteTrack
                && (!requireDirect || manifest.key.delivery == .direct)
        }) else { return false }
        let fileURL = directory.appendingPathComponent(match.fileName)
        guard (try? fileSize(at: fileURL)) == match.byteCount else {
            removeArtifactLocked(fileURL: fileURL)
            return false
        }
        return true
    }

    @discardableResult
    func recordCompleted(
        fileURL: URL,
        key: PlaybackArtifactKey,
        expectedDuration: TimeInterval?
    ) throws -> URL {
        guard key.isCompleteTrack else { return fileURL }
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        try ensureDirectory()

        let byteCount = try fileSize(at: fileURL)
        guard byteCount > 0 else {
            throw ProgressiveStreamError.invalidPayload(bytesReceived: byteCount)
        }
        try validateDurationIfPossible(fileURL: fileURL, expectedDuration: expectedDuration)

        let now = Date()
        try writeManifestLocked(PlaybackArtifactManifest(
            key: key,
            fileName: fileURL.lastPathComponent,
            byteCount: byteCount,
            expectedDuration: expectedDuration,
            completedAt: now,
            lastAccessedAt: now
        ))
        trimLocked(keepingTrackIdentities: [key.trackIdentity])
        notifyChange()
        return fileURL
    }

    func trim(keepingTrackIdentities: Set<String>) {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        trimLocked(keepingTrackIdentities: keepingTrackIdentities)
    }

    func removeArtifact(at fileURL: URL) {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        removeArtifactLocked(fileURL: fileURL)
        notifyChange()
    }

    func removeAll() throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        cachedManifests = [:]
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
        notifyChange()
    }

    func size() -> Int64 {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        return loadValidManifestsLocked()?.reduce(0) { $0 + $1.byteCount } ?? 0
    }

    private func trimLocked(keepingTrackIdentities: Set<String>) {
        guard let manifests = loadValidManifestsLocked() else { return }
        var total = manifests.reduce(Int64(0)) { $0 + $1.byteCount }
        var completeFileNames = Set(manifests.map(\.fileName))
        for manifest in manifests.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt })
        where total > byteBudget && !keepingTrackIdentities.contains(manifest.key.trackIdentity) {
            removeArtifactLocked(fileURL: directory.appendingPathComponent(manifest.fileName))
            completeFileNames.remove(manifest.fileName)
            total -= manifest.byteCount
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in files {
            guard !fileURL.lastPathComponent.hasSuffix(".manifest.json"),
                  !completeFileNames.contains(fileURL.lastPathComponent),
                  !PlaybackStreamCacheIdentity.shouldKeep(
                      fileName: fileURL.lastPathComponent,
                      keepIdentities: keepingTrackIdentities
                  ) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func loadValidManifestsLocked() -> [PlaybackArtifactManifest]? {
        if let cachedManifests { return Array(cachedManifests.values) }
        guard fileManager.fileExists(atPath: directory.path) else {
            cachedManifests = [:]
            return []
        }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var manifests: [PlaybackArtifactManifest] = []
        for manifestURL in urls where manifestURL.lastPathComponent.hasSuffix(".manifest.json") {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PlaybackArtifactManifest.self, from: data) else {
                try? fileManager.removeItem(at: manifestURL)
                continue
            }
            let fileURL = directory.appendingPathComponent(manifest.fileName)
            guard (try? fileSize(at: fileURL)) == manifest.byteCount else {
                removeArtifactLocked(fileURL: fileURL)
                continue
            }
            manifests.append(manifest)
        }
        cachedManifests = Dictionary(uniqueKeysWithValues: manifests.map { ($0.fileName, $0) })
        return manifests
    }

    private func writeManifestLocked(_ manifest: PlaybackArtifactManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(forFileName: manifest.fileName), options: .atomic)
        cachedManifests?[manifest.fileName] = manifest
    }

    private func manifestURL(forFileName fileName: String) -> URL {
        directory.appendingPathComponent("\(fileName).manifest.json")
    }

    private func removeArtifactLocked(fileURL: URL) {
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: manifestURL(forFileName: fileURL.lastPathComponent))
        cachedManifests?.removeValue(forKey: fileURL.lastPathComponent)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func validateDurationIfPossible(fileURL: URL, expectedDuration: TimeInterval?) throws {
        guard let expectedDuration, expectedDuration > 10 else { return }
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return }
            let actualDuration = Double(audioFile.length) / sampleRate
            guard actualDuration >= expectedDuration * 0.5 || actualDuration >= expectedDuration - 10 else {
                throw ProgressiveStreamError.invalidPayload(bytesReceived: try fileSize(at: fileURL))
            }
        } catch let error as ProgressiveStreamError {
            throw error
        } catch {
            EnsembleLogger.debug(
                "[PlaybackArtifactCache] duration validation unavailable for \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}
