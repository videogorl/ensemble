import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

// MARK: - Domain Models

/// A single line of lyrics, optionally with a timestamp for time-synced display
public struct LyricsLine: Sendable, Equatable {
    public let timestamp: TimeInterval?  // nil for plain text lines
    public let text: String
}

/// Parsed lyrics with metadata about whether they are time-synced
public struct ParsedLyrics: Sendable, Equatable {
    public let lines: [LyricsLine]
    public let isTimed: Bool

    /// Median inter-line interval for non-instrumental gaps.
    /// Represents how long a typical vocal line lasts in this song.
    /// Used to keep a line highlighted for a natural duration before
    /// instrumental dots take over.
    public let typicalVocalDuration: TimeInterval

    public init(lines: [LyricsLine], isTimed: Bool) {
        self.lines = lines
        self.isTimed = isTimed
        self.typicalVocalDuration = Self.computeTypicalVocalDuration(lines: lines, isTimed: isTimed)
    }

    /// Binary search for the active line at a given playback time.
    /// Returns the index of the last line whose timestamp <= time.
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        guard isTimed else { return nil }
        let timestamps = lines.compactMap { $0.timestamp }
        guard !timestamps.isEmpty else { return nil }

        var low = 0
        var high = timestamps.count - 1
        var result: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if timestamps[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Compute median interval between consecutive vocal lines (excluding instrumental gaps)
    private static func computeTypicalVocalDuration(lines: [LyricsLine], isTimed: Bool) -> TimeInterval {
        guard isTimed, lines.count > 1 else { return 2.0 }
        let instrumentalThreshold: TimeInterval = 5.0
        var intervals: [TimeInterval] = []
        for i in 0..<lines.count - 1 {
            guard let current = lines[i].timestamp,
                  let next = lines[i + 1].timestamp else { continue }
            let gap = next - current
            if gap > 0 && gap < instrumentalThreshold {
                intervals.append(gap)
            }
        }
        guard !intervals.isEmpty else { return 2.0 }
        intervals.sort()
        return intervals[intervals.count / 2]
    }
}

/// Current lyrics loading/display state
public enum LyricsState: Equatable {
    case loading
    case notAvailable
    case available(ParsedLyrics)

    /// Whether lyrics are loaded and available for display
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - LRC Parser

enum LRCParser {
    // Matches [MM:SS.XX] or [MM:SS.XXX] timestamp tags
    private static let timestampPattern = #"\[(\d{1,2}):(\d{2})\.(\d{2,3})\](.*)"#

    /// Parse LRC format text into lyrics lines
    static func parseLRC(_ text: String) -> ParsedLyrics {
        var lines: [LyricsLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip metadata tags like [au:], [by:], [ti:], [al:], [offset:]
            if isMetadataTag(trimmed) { continue }

            // Try to parse as timed line
            if let match = parseTimestampLine(trimmed) {
                lines.append(match)
            }
            // Skip lines that start with [ but aren't valid timestamps (other metadata)
        }

        // Sort by timestamp
        lines.sort { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }

        return ParsedLyrics(lines: lines, isTimed: true)
    }

    /// Parse plain text lyrics (no timestamps)
    static func parsePlainText(_ text: String) -> ParsedLyrics {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricsLine(timestamp: nil, text: $0) }

        return ParsedLyrics(lines: lines, isTimed: false)
    }

    // Check if a line is a metadata tag (e.g. [au:Author], [by:Creator])
    private static func isMetadataTag(_ line: String) -> Bool {
        guard line.hasPrefix("[") else { return false }
        // Metadata tags have format [key:value] where key is alphabetic
        guard let closeBracket = line.firstIndex(of: "]") else { return false }
        let tagContent = line[line.index(after: line.startIndex)..<closeBracket]
        guard let colonIndex = tagContent.firstIndex(of: ":") else { return false }
        let key = tagContent[tagContent.startIndex..<colonIndex]
        // If key is all alphabetic, it's metadata (au, by, ti, al, offset, etc.)
        return key.allSatisfy { $0.isLetter }
    }

    // Parse a single timed line like [01:23.45]Lyrics text here
    private static func parseTimestampLine(_ line: String) -> LyricsLine? {
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)

        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        guard match.numberOfRanges >= 5 else { return nil }

        guard let minutesRange = Range(match.range(at: 1), in: line),
              let secondsRange = Range(match.range(at: 2), in: line),
              let fracRange = Range(match.range(at: 3), in: line),
              let textRange = Range(match.range(at: 4), in: line) else { return nil }

        guard let minutes = Double(line[minutesRange]),
              let seconds = Double(line[secondsRange]) else { return nil }

        // Handle both .XX (centiseconds) and .XXX (milliseconds) formats
        let fracString = String(line[fracRange])
        let fracValue = Double(fracString) ?? 0
        let fractional = fracString.count == 2 ? fracValue / 100.0 : fracValue / 1000.0

        let timestamp = minutes * 60 + seconds + fractional
        let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)

        // Skip empty timed lines (instrumental breaks with no text)
        guard !text.isEmpty else { return nil }

        return LyricsLine(timestamp: timestamp, text: text)
    }
}

// MARK: - Lyrics Service

/// Orchestrates lyrics fetching, parsing, caching, and offline sidecar persistence.
/// Uses a two-tier cache: in-memory (session) + persistent file cache (survives restarts
/// and PMS LyricFind cache expiration).
@MainActor
public final class LyricsService: ObservableObject {
    @Published public private(set) var currentLyrics: LyricsState = .notAvailable

    // In-memory cache keyed by "ratingKey:sourceCompositeKey" (max ~20 entries)
    // Only caches successful results — .notAvailable is NOT cached so retries are possible
    private var cache: [String: LyricsState] = [:]
    private let maxCacheSize = 20

    // Cancel in-flight fetch on track change
    private var loadTask: Task<Void, Never>?

    private let syncCoordinator: SyncCoordinator
    private let downloadManager: DownloadManagerProtocol

    // Persistent lyrics cache directory
    private static let lyricsCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Ensemble/LyricsCache", isDirectory: true)
    }()

    public init(syncCoordinator: SyncCoordinator, downloadManager: DownloadManagerProtocol) {
        self.syncCoordinator = syncCoordinator
        self.downloadManager = downloadManager
        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: Self.lyricsCacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Load lyrics for a track. Cancels any in-flight fetch.
    public func loadLyrics(for track: Track) {
        loadTask?.cancel()

        let cacheKey = Self.cacheKey(for: track)

        // Check in-memory cache
        if let cached = cache[cacheKey] {
            currentLyrics = cached
            return
        }

        currentLyrics = .loading

        loadTask = Task { [weak self] in
            guard let self else { return }

            let result = await self.fetchLyrics(for: track)
            guard !Task.isCancelled else { return }

            self.setCached(result, forKey: cacheKey)
            self.currentLyrics = result
        }
    }

    /// Clear lyrics state (e.g. when playback stops)
    public func clearLyrics() {
        loadTask?.cancel()
        currentLyrics = .notAvailable
    }

    // MARK: - Fetch Pipeline

    private func fetchLyrics(for track: Track) async -> LyricsState {
        #if DEBUG
        EnsembleLogger.debug("Lyrics: starting fetch for track \(track.id) (\(track.title))")
        #endif

        // 1. Check for offline LRC sidecar (downloaded tracks)
        if let sidecarLyrics = await loadSidecarLyrics(for: track) {
            #if DEBUG
            EnsembleLogger.debug("Lyrics: loaded from sidecar (\(sidecarLyrics.lines.count) lines)")
            #endif
            return .available(sidecarLyrics)
        }

        // 2. Check persistent file cache (survives PMS LyricFind cache expiration)
        if let cachedContent = loadFromPersistentCache(for: track) {
            let parsed = parseContent(cachedContent, codec: nil)
            if let parsed {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: loaded from persistent cache (\(parsed.lines.count) lines)")
                #endif
                return .available(parsed)
            }
        }

        // 3. Fetch track metadata to discover lyrics streams
        guard let apiClient = syncCoordinator.apiClient(for: track.sourceCompositeKey) else {
            #if DEBUG
            EnsembleLogger.debug("Lyrics: no API client for source \(track.sourceCompositeKey ?? "nil")")
            #endif
            return .notAvailable
        }

        do {
            // Fetch full track metadata (includes Stream objects)
            guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: getTrack returned nil for \(track.id)")
                #endif
                return .notAvailable
            }

            #if DEBUG
            let streamCount = plexTrack.media?.first?.part?.first?.stream?.count ?? 0
            let lyricsStreams = plexTrack.media?.first?.part?.first?.stream?.filter { $0.streamType == 4 } ?? []
            EnsembleLogger.debug("Lyrics: track has \(streamCount) streams, \(lyricsStreams.count) lyrics streams")
            for ls in lyricsStreams {
                EnsembleLogger.debug("Lyrics:   stream id=\(ls.id) codec=\(ls.codec ?? "nil") timed=\(ls.timed.map(String.init) ?? "nil") key=\(ls.key ?? "nil")")
            }
            #endif

            guard let lyricsStream = plexTrack.lyricsStream,
                  let streamKey = lyricsStream.key else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: no lyrics stream found on track metadata")
                #endif
                return .notAvailable
            }

            // 4. Fetch lyrics content from PMS
            guard let content = try await apiClient.getLyricsContent(streamKey: streamKey) else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: content fetch returned nil for \(streamKey)")
                #endif
                return .notAvailable
            }

            guard !Task.isCancelled else { return .notAvailable }

            #if DEBUG
            let preview = String(content.prefix(300))
            EnsembleLogger.debug("Lyrics: content preview (\(content.count) chars): \(preview)")
            #endif

            // 5. Parse based on codec/format, with fallback to plain text
            let parsed = parseContent(content, codec: lyricsStream.codec)

            #if DEBUG
            EnsembleLogger.debug("Lyrics: parsed \(parsed?.lines.count ?? 0) lines (timed=\(parsed?.isTimed ?? false))")
            #endif

            guard let parsed, !parsed.lines.isEmpty else { return .notAvailable }

            // 6. Save to persistent cache and sidecar
            saveToPersistentCache(content, for: track)
            await saveSidecarIfDownloaded(for: track, content: content)

            return .available(parsed)
        } catch {
            if Task.isCancelled { return .notAvailable }
            #if DEBUG
            EnsembleLogger.debug("Lyrics: fetch failed for track \(track.id): \(error.localizedDescription)")
            #endif
            return .notAvailable
        }
    }

    /// Parse lyrics content, trying LRC first then falling back to plain text
    private func parseContent(_ content: String, codec: String?) -> ParsedLyrics? {
        // Try LRC first if codec suggests timed lyrics, or if content looks like LRC
        let looksLikeLRC = content.contains("[") && content.contains("]")
        if codec == "lrc" || looksLikeLRC {
            let parsed = LRCParser.parseLRC(content)
            if !parsed.lines.isEmpty { return parsed }
        }

        // Fall back to plain text
        let plain = LRCParser.parsePlainText(content)
        return plain.lines.isEmpty ? nil : plain
    }

    // MARK: - Sidecar Persistence

    /// Load lyrics from the .lrc sidecar file alongside a downloaded track
    private func loadSidecarLyrics(for track: Track) async -> ParsedLyrics? {
        guard let localPath = (try? await downloadManager.getLocalFilePath(
            forTrackRatingKey: track.id,
            sourceCompositeKey: track.sourceCompositeKey
        )) ?? nil else { return nil }

        let sidecarPath = localPath + ".lrc"
        guard FileManager.default.fileExists(atPath: sidecarPath),
              let data = FileManager.default.contents(atPath: sidecarPath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let parsed = LRCParser.parseLRC(content)
        // If the LRC parse produced no timed lines, try as plain text
        if parsed.lines.isEmpty {
            let plain = LRCParser.parsePlainText(content)
            return plain.lines.isEmpty ? nil : plain
        }
        return parsed
    }

    /// Save raw LRC content alongside a downloaded track for offline use
    private func saveSidecarIfDownloaded(for track: Track, content: String) async {
        guard let localPath = (try? await downloadManager.getLocalFilePath(
            forTrackRatingKey: track.id,
            sourceCompositeKey: track.sourceCompositeKey
        )) ?? nil else { return }

        let sidecarPath = localPath + ".lrc"
        try? content.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
    }

    /// Fetch and save lyrics sidecar for a track that was just downloaded.
    /// Called fire-and-forget after audio download completion.
    public nonisolated func fetchAndSaveSidecar(
        trackRatingKey: String,
        sourceCompositeKey: String?,
        localFilePath: String
    ) async {
        guard let sourceCompositeKey else { return }

        // Get the API client for this source
        let apiClient: PlexAPIClient? = await MainActor.run {
            syncCoordinator.apiClient(for: sourceCompositeKey)
        }
        guard let apiClient else { return }

        do {
            // Fetch track metadata to find lyrics stream
            guard let plexTrack = try await apiClient.getTrack(trackKey: trackRatingKey) else { return }
            guard let lyricsStream = plexTrack.lyricsStream,
                  let streamKey = lyricsStream.key else { return }

            // Fetch lyrics content
            guard let content = try await apiClient.getLyricsContent(streamKey: streamKey) else { return }

            // Write sidecar
            let sidecarPath = localFilePath + ".lrc"
            try content.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        } catch {
            // Best-effort; failure is not critical
        }
    }

    // MARK: - Persistent File Cache

    /// File path for a track's cached lyrics content
    private static func persistentCachePath(for track: Track) -> URL {
        let key = "\(track.id)_\(track.sourceCompositeKey ?? "local")"
        // Use a safe filename (replace non-alphanumeric chars)
        let safeKey = key.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return lyricsCacheDir.appendingPathComponent(safeKey + ".lrc")
    }

    /// Load lyrics content from persistent file cache
    private func loadFromPersistentCache(for track: Track) -> String? {
        let url = Self.persistentCachePath(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Save lyrics content to persistent file cache
    private func saveToPersistentCache(_ content: String, for track: Track) {
        let url = Self.persistentCachePath(for: track)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - In-Memory Cache Management

    private static func cacheKey(for track: Track) -> String {
        "\(track.id):\(track.sourceCompositeKey ?? "local")"
    }

    private func setCached(_ state: LyricsState, forKey key: String) {
        // Only cache successful results — don't cache .notAvailable so retries
        // are possible when PMS's LyricFind cache warms up
        guard case .available = state else { return }

        cache[key] = state

        // Evict oldest entries if over limit
        if cache.count > maxCacheSize {
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }
    }
}
