import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

// MARK: - Domain Models

/// A chord parsed from a UG-style chord row above a lyric row.
public struct ParsedChord: Sendable, Equatable {
    public let symbol: String
    public let column: Int
    public let offsetFromLyricStart: Int

    public init(symbol: String, column: Int, offsetFromLyricStart: Int) {
        self.symbol = symbol
        self.column = column
        self.offsetFromLyricStart = offsetFromLyricStart
    }
}

/// A single line of lyrics, optionally with a timestamp for time-synced display.
public struct LyricsLine: Sendable, Equatable {
    public let timestamp: TimeInterval?  // nil for plain text lines
    public let text: String
    public let chords: [ParsedChord]

    public init(timestamp: TimeInterval?, text: String, chords: [ParsedChord] = []) {
        self.timestamp = timestamp
        self.text = text
        self.chords = chords
    }
}

/// Parsed lyrics with metadata about whether they are time-synced
public struct ParsedLyrics: Sendable, Equatable {
    public let lines: [LyricsLine]
    public let isTimed: Bool
    public var containsChords: Bool { lines.contains { !$0.chords.isEmpty } }

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
        let timedLines = lines.enumerated().compactMap { index, line -> (index: Int, timestamp: TimeInterval)? in
            guard let timestamp = line.timestamp else { return nil }
            return (index, timestamp)
        }
        guard !timedLines.isEmpty else { return nil }

        var low = 0
        var high = timedLines.count - 1
        var result: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if timedLines[mid].timestamp <= time {
                result = timedLines[mid].index
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
public enum LyricsState: Equatable, Sendable {
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
    private static let timestampPattern = #"^\s*\[(\d{1,2}):(\d{2})\.(\d{2,3})\](.*)"#
    private static let chordPattern = #"(?<![A-Za-z0-9])\(?[A-G](?:#|b)?(?:maj|min|m|dim|aug|sus|add|dom)?\d*(?:/[A-G](?:#|b)?|/\d+)?\)?(?![A-Za-z0-9])"#

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

    /// Parse UG-style chord rows paired with the following lyric row.
    static func parseChordLRC(_ text: String) -> ParsedLyrics {
        var lines: [LyricsLine] = []
        var pendingChordRows: [String] = []
        var hasSeenTimestamp = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                continue
            }
            if isMetadataTag(trimmed) {
                continue
            }

            if let timestamped = parseTimestampLinePreservingText(line) {
                hasSeenTimestamp = true
                let chords = pendingChordRows.flatMap {
                    parseChordRow($0, timestampPrefixWidth: timestamped.prefixWidth)
                }
                pendingChordRows.removeAll()

                if !timestamped.text.isEmpty || !chords.isEmpty {
                    lines.append(LyricsLine(timestamp: timestamped.timestamp, text: timestamped.text, chords: chords))
                }
                continue
            }

            if isChordRow(line) {
                pendingChordRows.append(line)
                continue
            }

            let lyricText = line.trimmingCharacters(in: .whitespaces)
            if pendingChordRows.isEmpty, hasSeenTimestamp, let lastLine = lines.last, lastLine.timestamp != nil {
                let separator = lastLine.text.isEmpty ? "" : " "
                lines[lines.count - 1] = LyricsLine(
                    timestamp: lastLine.timestamp,
                    text: lastLine.text + separator + lyricText,
                    chords: lastLine.chords
                )
                continue
            }

            let chords = pendingChordRows.flatMap {
                parseChordRow($0, timestampPrefixWidth: 0)
            }
            pendingChordRows.removeAll()
            lines.append(LyricsLine(timestamp: nil, text: lyricText, chords: chords))
        }

        return ParsedLyrics(lines: lines, isTimed: lines.contains { $0.timestamp != nil })
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
        guard let parsed = parseTimestampLinePreservingText(line) else { return nil }

        let text = parsed.text.trimmingCharacters(in: .whitespaces)

        // Skip empty timed lines (instrumental breaks with no text)
        guard !text.isEmpty else { return nil }

        return LyricsLine(timestamp: parsed.timestamp, text: text)
    }

    private static func parseTimestampLinePreservingText(_ line: String) -> (timestamp: TimeInterval, text: String, prefixWidth: Int)? {
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
        let text = String(line[textRange])
        let prefixWidth = match.range(at: 0).length - match.range(at: 4).length

        return (timestamp, text, prefixWidth)
    }

    private static func isChordRow(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: chordPattern) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        let matches = regex.matches(in: line, range: range)
        guard !matches.isEmpty else { return false }
        let nonWhitespaceCount = line.filter { !$0.isWhitespace }.count
        let chordChars = matches.reduce(0) { $0 + $1.range.length }
        return chordChars >= max(1, nonWhitespaceCount - 2)
    }

    private static func parseChordRow(_ row: String, timestampPrefixWidth: Int) -> [ParsedChord] {
        guard let regex = try? NSRegularExpression(pattern: chordPattern) else { return [] }
        let range = NSRange(row.startIndex..., in: row)
        return regex.matches(in: row, range: range).compactMap { match in
            guard let symbolRange = Range(match.range, in: row) else { return nil }
            let column = row.distance(from: row.startIndex, to: symbolRange.lowerBound)
            return ParsedChord(
                symbol: String(row[symbolRange]),
                column: column,
                offsetFromLyricStart: column - timestampPrefixWidth
            )
        }
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
    @Published public private(set) var hasChordLyricsForCurrentTrack = false
    @Published public private(set) var isDisplayingChordLyrics = false

    // In-memory cache keyed by "ratingKey:sourceCompositeKey" (max ~20 entries).
    // Both .available and .notAvailable results are cached. Negative entries expire
    // after 30 minutes to allow retries once PMS's LyricFind cache warms up.
    private var cache: [String: LyricsState] = [:]
    private var negativeCacheTimestamps: [String: Date] = [:]
    private let maxCacheSize = 20
    private let negativeCacheTTL: TimeInterval = 30 * 60  // 30 minutes

    // Cancel in-flight fetch on track change
    private var loadTask: Task<Void, Never>?
    private var chordModeEnabled = false
    private var activeBundle: LyricsBundle?

    private let syncCoordinator: SyncCoordinator

    private enum LyricsMode: String, Sendable {
        case lyrics
        case chords
    }

    private struct LyricsBundle: Sendable {
        var normalState: LyricsState
        var normalSource: LyricsSource
        var chordState: LyricsState
        var chordSource: LyricsSource
    }

    private struct LyricsStreamSignature: Codable, Equatable, Sendable {
        let streamID: Int
        let provider: String?
        let codec: String?
        let format: String?
        let file: String?
        let trackDateModified: TimeInterval?
    }

    private struct PersistentLyricsCacheEntry: Codable, Sendable {
        let content: String
        let signature: LyricsStreamSignature
        let savedAt: Date
    }

    // Persistent lyrics cache directory
    private nonisolated static let lyricsCacheDir: URL = {
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

        currentLyrics = .loading
        currentLyricsSource = .none
        hasChordLyricsForCurrentTrack = false
        isDisplayingChordLyrics = false
        activeBundle = nil

        loadTask = Task { [weak self] in
            guard let self else { return }

            let bundle = await self.fetchLyrics(for: track)
            guard !Task.isCancelled else {
                self.currentLyricsSource = .cancelled
                return
            }

            self.activeBundle = bundle
            self.publishActiveBundle()
        }
    }

    public func setChordModeEnabled(_ enabled: Bool) {
        chordModeEnabled = enabled
        publishActiveBundle()
    }

    /// Clear lyrics state (e.g. when playback stops)
    public func clearLyrics() {
        loadTask?.cancel()
        currentLyrics = .notAvailable
        currentLyricsSource = .none
        hasChordLyricsForCurrentTrack = false
        isDisplayingChordLyrics = false
        activeBundle = nil
    }

    /// Force a fresh lyrics fetch for the current track by evicting any cached
    /// negative result before re-running the normal load pipeline.
    public func retryLyrics(for track: Track) {
        loadTask?.cancel()
        clearCache(forTrackRatingKey: track.id, sourceCompositeKey: track.sourceCompositeKey ?? "local")
        loadLyrics(for: track)
    }

    #if DEBUG
    /// Test seam for view-model timing coverage without hitting the network/cache pipeline.
    func setLyricsStateForTesting(_ state: LyricsState, source: LyricsSource = .server) {
        loadTask?.cancel()
        activeBundle = LyricsBundle(normalState: state, normalSource: source, chordState: .notAvailable, chordSource: .none)
        publishActiveBundle()
    }

    func setLyricsBundleForTesting(normal: LyricsState, chords: LyricsState, chordModeEnabled: Bool = false) {
        loadTask?.cancel()
        self.chordModeEnabled = chordModeEnabled
        activeBundle = LyricsBundle(normalState: normal, normalSource: .server, chordState: chords, chordSource: .server)
        publishActiveBundle()
    }
    #endif

    // MARK: - Fetch Pipeline

    private func publishActiveBundle() {
        guard let bundle = activeBundle else {
            hasChordLyricsForCurrentTrack = false
            isDisplayingChordLyrics = false
            return
        }

        let chordAvailable = bundle.chordState.isAvailable
        hasChordLyricsForCurrentTrack = chordAvailable

        if chordModeEnabled, chordAvailable {
            currentLyrics = bundle.chordState
            currentLyricsSource = bundle.chordSource
            isDisplayingChordLyrics = true
        } else {
            currentLyrics = bundle.normalState
            currentLyricsSource = bundle.normalSource
            isDisplayingChordLyrics = false
        }
    }

    private func fetchLyrics(for track: Track) async -> LyricsBundle {
        EnsembleLogger.debug("Lyrics: starting fetch for track \(track.id) (\(track.title))")

        // Skip server fetch when offline, but allow downloaded/cached lyric sidecars
        // to support playback without current Plex stream metadata.
        if syncCoordinator.isOffline {
            let normal = Self.loadOfflineCachedState(for: track, mode: .lyrics)
            let chords = Self.loadOfflineCachedState(for: track, mode: .chords)
            if normal != nil || chords != nil {
                EnsembleLogger.debug("Lyrics: offline, loaded cached sidecar state for track \(track.id)")
                return LyricsBundle(
                    normalState: normal?.0 ?? .notAvailable,
                    normalSource: normal?.1 ?? .noApiClient,
                    chordState: chords?.0 ?? .notAvailable,
                    chordSource: chords?.1 ?? .noApiClient
                )
            }

            EnsembleLogger.debug("Lyrics: offline, no cached lyrics for track \(track.id)")
            return LyricsBundle(
                normalState: .notAvailable,
                normalSource: .noApiClient,
                chordState: .notAvailable,
                chordSource: .noApiClient
            )
        }

        // 2. Fetch track metadata to discover lyrics streams
        guard let apiClient = syncCoordinator.apiClient(for: track.sourceCompositeKey) else {
            EnsembleLogger.debug("Lyrics: no API client for source \(track.sourceCompositeKey ?? "nil")")
            return LyricsBundle(normalState: .notAvailable, normalSource: .noApiClient, chordState: .notAvailable, chordSource: .noApiClient)
        }

        do {
            // Fetch full track metadata (includes Stream objects)
            guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else {
                EnsembleLogger.debug("Lyrics: getTrack returned nil for \(track.id)")
                return LyricsBundle(normalState: .notAvailable, normalSource: .trackMetadataFailed, chordState: .notAvailable, chordSource: .trackMetadataFailed)
            }

            let streamCount = plexTrack.media?.first?.part?.first?.stream?.count ?? 0
            let lyricsStreams = plexTrack.media?.first?.part?.first?.stream?.filter { $0.streamType == 4 } ?? []
            EnsembleLogger.debug("Lyrics: track has \(streamCount) streams, \(lyricsStreams.count) lyrics streams")
            for ls in lyricsStreams {
                EnsembleLogger.debug("Lyrics:   stream id=\(ls.id) codec=\(ls.codec ?? "nil") timed=\(ls.timed.map(String.init) ?? "nil") key=\(ls.key ?? "nil") provider=\(ls.provider ?? "nil") file=\(ls.file ?? "nil")")
            }

            guard !plexTrack.lyricsStreams.isEmpty else {
                EnsembleLogger.debug("Lyrics: no lyrics stream found on track metadata")
                return LyricsBundle(normalState: .notAvailable, normalSource: .noLyricsStream, chordState: .notAvailable, chordSource: .noLyricsStream)
            }

            let normal = await fetchNormalLyrics(track: track, stream: plexTrack.lyricsStream, apiClient: apiClient)
            let chords = await fetchChordLyrics(track: track, streams: plexTrack.chordCandidateStreams, apiClient: apiClient)
            return LyricsBundle(normalState: normal.0, normalSource: normal.1, chordState: chords.0, chordSource: chords.1)
        } catch {
            if Task.isCancelled {
                return LyricsBundle(normalState: .notAvailable, normalSource: .cancelled, chordState: .notAvailable, chordSource: .cancelled)
            }
            EnsembleLogger.debug("Lyrics: fetch failed for track \(track.id): \(error.localizedDescription)")
            return LyricsBundle(normalState: .notAvailable, normalSource: .trackMetadataFailed, chordState: .notAvailable, chordSource: .trackMetadataFailed)
        }
    }

    private func fetchNormalLyrics(
        track: Track,
        stream: PlexStream?,
        apiClient: PlexAPIClient
    ) async -> (LyricsState, LyricsSource) {
        guard let stream, let streamKey = stream.key else {
            return (.notAvailable, .noLyricsStream)
        }

        let signature = Self.streamSignature(for: track, stream: stream)
        let key = Self.cacheKey(for: track, stream: stream, mode: .lyrics)
        if let cached = loadCachedState(key: key) {
            return (cached, .memoryCache)
        }
        if let cachedContent = loadFromPersistentCache(key: key, signature: signature, mode: .lyrics),
           let parsed = Self.parseContent(cachedContent, codec: stream.codec) {
            let state = LyricsState.available(parsed)
            setCached(state, forKey: key)
            EnsembleLogger.debug("Lyrics: loaded normal lyrics from persistent cache (\(parsed.lines.count) lines)")
            return (state, .persistentCache)
        }

        do {
            guard let content = try await apiClient.getLyricsContent(streamKey: streamKey) else {
                return (.notAvailable, .contentFetchFailed)
            }
            guard !Task.isCancelled else { return (.notAvailable, .cancelled) }
            guard let parsed = Self.parseContent(content, codec: stream.codec), !parsed.lines.isEmpty else {
                return (.notAvailable, .parseFailed)
            }
            let state = LyricsState.available(parsed)
            saveToPersistentCache(content, key: key, signature: signature)
            setCached(state, forKey: key)
            return (state, .server)
        } catch {
            if Task.isCancelled { return (.notAvailable, .cancelled) }
            return (.notAvailable, .contentFetchFailed)
        }
    }

    private func fetchChordLyrics(
        track: Track,
        streams: [PlexStream],
        apiClient: PlexAPIClient
    ) async -> (LyricsState, LyricsSource) {
        guard !streams.isEmpty else {
            return (.notAvailable, .noLyricsStream)
        }

        for stream in streams {
            guard let streamKey = stream.key else { continue }
            let signature = Self.streamSignature(for: track, stream: stream)
            let key = Self.cacheKey(for: track, stream: stream, mode: .chords)

            do {
                guard let content = try await apiClient.getRawLyricsContent(streamKey: streamKey) else {
                    if let cached = cachedChordState(forKey: key, signature: signature) {
                        return cached
                    }
                    continue
                }
                guard !Task.isCancelled else { return (.notAvailable, .cancelled) }
                guard let parsed = Self.parseChordContent(content), parsed.containsChords else {
                    EnsembleLogger.debug("Lyrics: fetched chord stream \(stream.id) but content did not parse as chords")
                    continue
                }
                let state = LyricsState.available(parsed)
                saveToPersistentCache(content, key: key, signature: signature)
                setCached(state, forKey: key)
                return (state, .server)
            } catch {
                if Task.isCancelled { return (.notAvailable, .cancelled) }
                if let cached = cachedChordState(forKey: key, signature: signature) {
                    return cached
                }
                continue
            }
        }

        return (.notAvailable, .parseFailed)
    }

    private func cachedChordState(
        forKey key: String,
        signature: LyricsStreamSignature
    ) -> (LyricsState, LyricsSource)? {
        if let cached = loadCachedState(key: key) {
            return (cached, .memoryCache)
        }
        if let cachedContent = loadFromPersistentCache(key: key, signature: signature, mode: .chords),
           let parsed = Self.parseChordContent(cachedContent), parsed.containsChords {
            let state = LyricsState.available(parsed)
            setCached(state, forKey: key)
            EnsembleLogger.debug("Lyrics: loaded chord lyrics from persistent cache after fresh fetch failed (\(parsed.lines.count) lines)")
            return (state, .persistentCache)
        }
        return nil
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

    private nonisolated static func parseChordContent(_ content: String) -> ParsedLyrics? {
        let parsed = LRCParser.parseChordLRC(content)
        return parsed.lines.isEmpty ? nil : parsed
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
            let track = Track(
                id: trackRatingKey,
                key: "/library/metadata/\(trackRatingKey)",
                title: plexTrack.title,
                dateModified: plexTrack.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sourceCompositeKey: sourceCompositeKey
            )

            if let lyricsStream = plexTrack.lyricsStream,
               let streamKey = lyricsStream.key,
               let content = try await apiClient.getLyricsContent(streamKey: streamKey),
               Self.parseContent(content, codec: lyricsStream.codec) != nil {
                let signature = Self.streamSignature(for: track, stream: lyricsStream)
                let key = Self.cacheKey(for: track, stream: lyricsStream, mode: .lyrics)
                saveToPersistentCache(content, key: key, signature: signature)
            }

            for chordStream in plexTrack.chordCandidateStreams {
                guard let streamKey = chordStream.key,
                      let content = try await apiClient.getRawLyricsContent(streamKey: streamKey),
                      let parsed = Self.parseChordContent(content),
                      parsed.containsChords else {
                    continue
                }
                let signature = Self.streamSignature(for: track, stream: chordStream)
                let key = Self.cacheKey(for: track, stream: chordStream, mode: .chords)
                saveToPersistentCache(content, key: key, signature: signature)
                break
            }
        } catch {
            // Best-effort; failure is not critical
        }
    }

    // MARK: - Cache Cleanup

    /// Clear all persistent lyrics caches and in-memory cache.
    /// Called by CacheManager when user clears all library data.
    @discardableResult
    public func clearAllCaches() -> Int {
        let removedInMemoryCount = cache.count + negativeCacheTimestamps.count
        cache.removeAll()
        negativeCacheTimestamps.removeAll()
        let removedFileCount = (try? FileManager.default.contentsOfDirectory(atPath: Self.lyricsCacheDir.path).count) ?? 0
        try? FileManager.default.removeItem(at: Self.lyricsCacheDir)
        try? FileManager.default.createDirectory(at: Self.lyricsCacheDir, withIntermediateDirectories: true)
        return removedInMemoryCount + removedFileCount
    }

    /// Clear persistent lyrics cache files for a specific source.
    /// Called when an account or library is removed.
    @discardableResult
    public func clearCache(forSourceCompositeKey sourceKey: String) -> Int {
        // Remove matching in-memory cache entries
        let oldCacheCount = cache.count
        let oldNegativeCount = negativeCacheTimestamps.count
        cache = cache.filter { !$0.key.contains(":\(sourceKey):") }
        negativeCacheTimestamps = negativeCacheTimestamps.filter { !$0.key.contains(":\(sourceKey):") }
        var removedCount = (oldCacheCount - cache.count) + (oldNegativeCount - negativeCacheTimestamps.count)

        // Remove matching persistent cache files (filename contains the source key)
        let safeSourceKey = sourceKey.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.lyricsCacheDir.path) else { return removedCount }
        for file in files where file.contains(safeSourceKey) {
            if (try? FileManager.default.removeItem(at: Self.lyricsCacheDir.appendingPathComponent(file))) != nil {
                removedCount += 1
            }
        }
        return removedCount
    }

    /// Remove cached lyrics for a single track/source pair.
    public func clearCache(forTrackRatingKey ratingKey: String, sourceCompositeKey sourceKey: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(ratingKey):\(sourceKey):") }
        negativeCacheTimestamps = negativeCacheTimestamps.filter { !$0.key.hasPrefix("\(ratingKey):\(sourceKey):") }
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.lyricsCacheDir.path) else { return }
        let safePrefix = Self.safeFilename("\(ratingKey):\(sourceKey):")
        for file in files where file.hasPrefix(safePrefix) {
            try? FileManager.default.removeItem(at: Self.lyricsCacheDir.appendingPathComponent(file))
        }
    }

    // MARK: - Persistent File Cache

    private nonisolated static func persistentCachePath(key: String) -> URL {
        lyricsCacheDir.appendingPathComponent(safeFilename(key) + ".json")
    }

    private nonisolated static func safeFilename(_ key: String) -> String {
        key.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
    }

    private nonisolated static func loadOfflineCachedState(
        for track: Track,
        mode: LyricsMode
    ) -> (LyricsState, LyricsSource)? {
        let sourceKey = track.sourceCompositeKey ?? "local"
        let prefix = safeFilename("\(track.id):\(sourceKey):\(mode.rawValue):")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: lyricsCacheDir.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        let entries = files.compactMap { file -> PersistentLyricsCacheEntry? in
            guard file.hasPrefix(prefix) else { return nil }
            let url = lyricsCacheDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PersistentLyricsCacheEntry.self, from: data)
        }
        .sorted { $0.savedAt > $1.savedAt }

        for entry in entries {
            switch mode {
            case .lyrics:
                if let parsed = parseContent(entry.content, codec: entry.signature.codec), !parsed.lines.isEmpty {
                    return (.available(parsed), .persistentCache)
                }
            case .chords:
                if let parsed = parseChordContent(entry.content), parsed.containsChords {
                    return (.available(parsed), .persistentCache)
                }
            }
        }

        return nil
    }

    private func loadFromPersistentCache(key: String, signature: LyricsStreamSignature, mode: LyricsMode) -> String? {
        let url = Self.persistentCachePath(key: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(PersistentLyricsCacheEntry.self, from: data),
              entry.signature == signature else {
            return nil
        }

        if mode == .chords, Date().timeIntervalSince(entry.savedAt) > 24 * 60 * 60 {
            return nil
        }

        return entry.content
    }

    private nonisolated func saveToPersistentCache(_ content: String, key: String, signature: LyricsStreamSignature) {
        let entry = PersistentLyricsCacheEntry(content: content, signature: signature, savedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: Self.persistentCachePath(key: key), options: .atomic)
    }

    // MARK: - In-Memory Cache Management

    private nonisolated static func cacheKey(for track: Track, stream: PlexStream, mode: LyricsMode) -> String {
        [
            track.id,
            track.sourceCompositeKey ?? "local",
            mode.rawValue,
            String(stream.id),
            stream.provider ?? "unknown",
            stream.codec ?? "unknown",
            stream.format ?? "unknown"
        ].joined(separator: ":")
    }

    private nonisolated static func streamSignature(for track: Track, stream: PlexStream) -> LyricsStreamSignature {
        LyricsStreamSignature(
            streamID: stream.id,
            provider: stream.provider,
            codec: stream.codec,
            format: stream.format,
            file: stream.file,
            trackDateModified: track.dateModified?.timeIntervalSince1970
        )
    }

    private func loadCachedState(key: String) -> LyricsState? {
        guard let cached = cache[key] else { return nil }
        if case .notAvailable = cached,
           let timestamp = negativeCacheTimestamps[key],
           Date().timeIntervalSince(timestamp) >= negativeCacheTTL {
            cache.removeValue(forKey: key)
            negativeCacheTimestamps.removeValue(forKey: key)
            return nil
        }
        return cached
    }

    private func setCached(_ state: LyricsState, forKey key: String) {
        // Skip caching transient states
        guard case .available = state else {
            // Cache .notAvailable with a timestamp so it expires after negativeCacheTTL.
            // This prevents 18-request storms when the same 404 stream is retried per
            // track visit, while still allowing retries once PMS's LyricFind cache warms up.
            if case .notAvailable = state {
                cache[key] = state
                negativeCacheTimestamps[key] = Date()
            }
            return
        }

        cache[key] = state
        // Clear any negative timestamp if we now have a positive result
        negativeCacheTimestamps.removeValue(forKey: key)

        // Evict oldest entries if over limit
        if cache.count > maxCacheSize {
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
                negativeCacheTimestamps.removeValue(forKey: firstKey)
            }
        }
    }
}
