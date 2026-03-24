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

    /// Median inter-line interval for vocal lines (excluding instrumental gaps).
    /// Represents how long a typical vocal line lasts in this song.
    /// Used to keep a line highlighted for a natural duration before
    /// instrumental dots take over.
    public let typicalVocalDuration: TimeInterval

    /// Adaptive threshold for detecting instrumental gaps.
    /// Gaps between lyrics lines longer than this are considered instrumental breaks.
    /// Computed as max(median_interval * 2.0, 10.0) so songs with naturally
    /// longer phrase spacing (e.g. ballads) don't get false instrumental dots.
    public let instrumentalGapThreshold: TimeInterval

    public init(lines: [LyricsLine], isTimed: Bool) {
        self.lines = lines
        self.isTimed = isTimed
        let (vocal, threshold) = Self.computeTimingParameters(lines: lines, isTimed: isTimed)
        self.typicalVocalDuration = vocal
        self.instrumentalGapThreshold = threshold
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

    /// Two-pass computation of vocal duration and instrumental gap threshold.
    /// Pass 1: Compute median of ALL inter-line intervals to understand the song's pacing.
    /// Pass 2: Set instrumental threshold adaptively, then compute vocal duration
    ///         as the median of intervals below that threshold.
    private static func computeTimingParameters(
        lines: [LyricsLine], isTimed: Bool
    ) -> (vocalDuration: TimeInterval, gapThreshold: TimeInterval) {
        let defaultVocal: TimeInterval = 2.0
        let minimumThreshold: TimeInterval = 10.0

        guard isTimed, lines.count > 1 else {
            return (defaultVocal, minimumThreshold)
        }

        // Collect all positive inter-line intervals
        var allIntervals: [TimeInterval] = []
        for i in 0..<lines.count - 1 {
            guard let current = lines[i].timestamp,
                  let next = lines[i + 1].timestamp else { continue }
            let gap = next - current
            if gap > 0 { allIntervals.append(gap) }
        }

        guard !allIntervals.isEmpty else {
            return (defaultVocal, minimumThreshold)
        }

        allIntervals.sort()
        let medianInterval = allIntervals[allIntervals.count / 2]

        // Instrumental threshold: at least 2x the song's natural pacing, minimum 10s.
        // This prevents false dots on songs with naturally long phrase spacing.
        let gapThreshold = max(medianInterval * 2.0, minimumThreshold)

        // Vocal duration: median of intervals below the threshold
        let vocalIntervals = allIntervals.filter { $0 < gapThreshold }
        let vocalDuration: TimeInterval
        if vocalIntervals.isEmpty {
            vocalDuration = defaultVocal
        } else {
            vocalDuration = vocalIntervals[vocalIntervals.count / 2]
        }

        return (vocalDuration, gapThreshold)
    }
}

/// Describes where lyrics were sourced from or why they're unavailable.
/// Displayed in the Info card for diagnostic purposes.
public enum LyricsSource: Equatable, Sendable {
    // Available sources
    case memoryCache          // Served from in-memory session cache
    case persistentCache      // Served from on-disk cache (survives restarts)
    case server               // Freshly fetched from Plex server

    // Unavailable reasons
    case noApiClient          // No API client for this source (offline/unconfigured)
    case trackMetadataFailed  // Failed to fetch track metadata from server
    case noLyricsStream       // Track metadata has no lyrics stream (streamType=4)
    case contentFetchFailed   // Lyrics stream exists but content fetch failed (404/timeout)
    case parseFailed          // Content fetched but couldn't be parsed
    case cancelled            // Fetch cancelled (track changed)
    case none                 // Initial/cleared state

    /// User-facing description for InfoCard
    public var displayText: String {
        switch self {
        case .memoryCache: return "Cached (Memory)"
        case .persistentCache: return "Cached (Disk)"
        case .server: return "Fetched from Server"
        case .noApiClient: return "No Server Connection"
        case .trackMetadataFailed: return "Metadata Fetch Failed"
        case .noLyricsStream: return "Not Available on Server"
        case .contentFetchFailed: return "Content Fetch Failed"
        case .parseFailed: return "Parse Error"
        case .cancelled: return "Cancelled"
        case .none: return "—"
        }
    }

    /// Whether this source indicates lyrics are available
    public var isAvailable: Bool {
        switch self {
        case .memoryCache, .persistentCache, .server: return true
        default: return false
        }
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

/// Orchestrates lyrics fetching, parsing, and caching.
/// Uses a two-tier cache: in-memory (session) + persistent file cache (survives restarts
/// and PMS LyricFind cache expiration).
@MainActor
public final class LyricsService: ObservableObject {
    @Published public private(set) var currentLyrics: LyricsState = .notAvailable
    @Published public private(set) var currentLyricsSource: LyricsSource = .none

    // In-memory cache keyed by "ratingKey:sourceCompositeKey" (max ~20 entries)
    // Only caches successful results — .notAvailable is NOT cached so retries are possible
    private var cache: [String: LyricsState] = [:]
    private let maxCacheSize = 20

    // Cancel in-flight fetch on track change
    private var loadTask: Task<Void, Never>?

    private let syncCoordinator: SyncCoordinator

    // Persistent lyrics cache directory
    private static let lyricsCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Ensemble/LyricsCache", isDirectory: true)
    }()

    public init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
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
            currentLyricsSource = .memoryCache
            return
        }

        currentLyrics = .loading
        currentLyricsSource = .none

        loadTask = Task { [weak self] in
            guard let self else { return }

            let (result, source) = await self.fetchLyrics(for: track)
            guard !Task.isCancelled else {
                self.currentLyricsSource = .cancelled
                return
            }

            self.setCached(result, forKey: cacheKey)
            self.currentLyrics = result
            self.currentLyricsSource = source
        }
    }

    /// Clear lyrics state (e.g. when playback stops)
    public func clearLyrics() {
        loadTask?.cancel()
        currentLyrics = .notAvailable
        currentLyricsSource = .none
    }

    #if DEBUG
    /// Test seam for view-model timing coverage without hitting the network/cache pipeline.
    func setLyricsStateForTesting(_ state: LyricsState, source: LyricsSource = .server) {
        loadTask?.cancel()
        currentLyrics = state
        currentLyricsSource = source
    }
    #endif

    // MARK: - Fetch Pipeline

    private func fetchLyrics(for track: Track) async -> (LyricsState, LyricsSource) {
        #if DEBUG
        EnsembleLogger.debug("Lyrics: starting fetch for track \(track.id) (\(track.title))")
        #endif

        // 1. Check persistent file cache (survives PMS LyricFind cache expiration)
        if let cachedContent = loadFromPersistentCache(for: track) {
            let parsed = Self.parseContent(cachedContent, codec: nil)
            if let parsed {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: loaded from persistent cache (\(parsed.lines.count) lines)")
                #endif
                return (.available(parsed), .persistentCache)
            }
        }

        // 2. Fetch track metadata to discover lyrics streams
        guard let apiClient = syncCoordinator.apiClient(for: track.sourceCompositeKey) else {
            #if DEBUG
            EnsembleLogger.debug("Lyrics: no API client for source \(track.sourceCompositeKey ?? "nil")")
            #endif
            return (.notAvailable, .noApiClient)
        }

        do {
            // Fetch full track metadata (includes Stream objects)
            guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: getTrack returned nil for \(track.id)")
                #endif
                return (.notAvailable, .trackMetadataFailed)
            }

            #if DEBUG
            let streamCount = plexTrack.media?.first?.part?.first?.stream?.count ?? 0
            let lyricsStreams = plexTrack.media?.first?.part?.first?.stream?.filter { $0.streamType == 4 } ?? []
            EnsembleLogger.debug("Lyrics: track has \(streamCount) streams, \(lyricsStreams.count) lyrics streams")
            for ls in lyricsStreams {
                EnsembleLogger.debug("Lyrics:   stream id=\(ls.id) codec=\(ls.codec ?? "nil") timed=\(ls.timed.map(String.init) ?? "nil") key=\(ls.key ?? "nil") provider=\(ls.provider ?? "nil")")
            }
            #endif

            guard let lyricsStream = plexTrack.lyricsStream,
                  let streamKey = lyricsStream.key else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: no lyrics stream found on track metadata")
                #endif
                return (.notAvailable, .noLyricsStream)
            }

            // 3. Fetch lyrics content from PMS
            let content: String
            if let fetched = try await apiClient.getLyricsContent(streamKey: streamKey) {
                content = fetched
            } else {
                #if DEBUG
                EnsembleLogger.debug("Lyrics: content fetch returned nil for \(streamKey) — scheduling background retry in 10s")
                #endif
                // Schedule a lazy background retry after 10s (don't block UI).
                // PMS may need time to re-fetch from LyricFind, especially on iOS 15.
                let codec = lyricsStream.codec
                let cacheKey = Self.cacheKey(for: track)
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                    guard !Task.isCancelled else { return }
                    guard let retryContent = try? await apiClient.getLyricsContent(streamKey: streamKey) else {
                        #if DEBUG
                        EnsembleLogger.debug("Lyrics: background retry also failed for \(streamKey)")
                        #endif
                        return
                    }
                    #if DEBUG
                    EnsembleLogger.debug("Lyrics: background retry succeeded for \(streamKey) (\(retryContent.count) chars)")
                    #endif
                    let parsed = Self.parseContent(retryContent, codec: codec)
                    guard let parsed, !parsed.lines.isEmpty else { return }
                    // Save to persistent cache and update state on main actor
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.saveToPersistentCache(retryContent, for: track)
                        self.setCached(.available(parsed), forKey: cacheKey)
                        // Update current state if lyrics are still showing as unavailable
                        // (i.e. the user hasn't switched tracks)
                        if case .notAvailable = self.currentLyrics {
                            self.currentLyrics = .available(parsed)
                            self.currentLyricsSource = .server
                        }
                    }
                }
                return (.notAvailable, .contentFetchFailed)
            }

            guard !Task.isCancelled else { return (.notAvailable, .cancelled) }

            #if DEBUG
            let preview = String(content.prefix(300))
            EnsembleLogger.debug("Lyrics: content preview (\(content.count) chars): \(preview)")
            #endif

            // 4. Parse based on codec/format, with fallback to plain text
            let parsed = Self.parseContent(content, codec: lyricsStream.codec)

            #if DEBUG
            EnsembleLogger.debug("Lyrics: parsed \(parsed?.lines.count ?? 0) lines (timed=\(parsed?.isTimed ?? false))")
            #endif

            guard let parsed, !parsed.lines.isEmpty else {
                return (.notAvailable, .parseFailed)
            }

            // 5. Save to persistent cache
            saveToPersistentCache(content, for: track)

            return (.available(parsed), .server)
        } catch {
            if Task.isCancelled { return (.notAvailable, .cancelled) }
            #if DEBUG
            EnsembleLogger.debug("Lyrics: fetch failed for track \(track.id): \(error.localizedDescription)")
            #endif
            return (.notAvailable, .trackMetadataFailed)
        }
    }

    /// Parse lyrics content, trying LRC first then falling back to plain text
    private nonisolated static func parseContent(_ content: String, codec: String?) -> ParsedLyrics? {
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

    // MARK: - Pre-Cache for Downloads

    /// Fetch and cache lyrics for a track that was just downloaded.
    /// Called fire-and-forget after audio download completion so lyrics
    /// are available immediately when the user plays the track offline.
    public nonisolated func fetchAndCacheLyrics(
        trackRatingKey: String,
        sourceCompositeKey: String?
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

            // Parse and save to persistent cache
            let parsed = Self.parseContent(content, codec: lyricsStream.codec)
            guard parsed != nil else { return }
            saveToPersistentCache(content: content, ratingKey: trackRatingKey, sourceKey: sourceCompositeKey)
        } catch {
            // Best-effort; failure is not critical
        }
    }

    // MARK: - Cache Cleanup

    /// Clear all persistent lyrics caches and in-memory cache.
    /// Called by CacheManager when user clears all library data.
    public func clearAllCaches() {
        cache.removeAll()
        try? FileManager.default.removeItem(at: Self.lyricsCacheDir)
        try? FileManager.default.createDirectory(at: Self.lyricsCacheDir, withIntermediateDirectories: true)
    }

    /// Clear persistent lyrics cache files for a specific source.
    /// Called when an account or library is removed.
    public func clearCache(forSourceCompositeKey sourceKey: String) {
        // Remove matching in-memory cache entries
        cache = cache.filter { !$0.key.hasSuffix(":\(sourceKey)") }

        // Remove matching persistent cache files (filename contains the source key)
        let safeSourceKey = sourceKey.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.lyricsCacheDir.path) else { return }
        for file in files where file.contains(safeSourceKey) {
            try? FileManager.default.removeItem(at: Self.lyricsCacheDir.appendingPathComponent(file))
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

    /// File path for a track's cached lyrics by ratingKey and sourceKey
    private nonisolated static func persistentCachePath(ratingKey: String, sourceKey: String) -> URL {
        let key = "\(ratingKey)_\(sourceKey)"
        let safeKey = key.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return lyricsCacheDir.appendingPathComponent(safeKey + ".lrc")
    }

    /// Save lyrics content to persistent file cache by ratingKey and sourceKey
    private nonisolated func saveToPersistentCache(content: String, ratingKey: String, sourceKey: String) {
        let url = Self.persistentCachePath(ratingKey: ratingKey, sourceKey: sourceKey)
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
