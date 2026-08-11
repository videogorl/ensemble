import Combine
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
    private static let chordPattern = #"(?<![A-Za-z0-9])\(?[A-G](?:#|b)?(?:(?:maj|min|dim|aug|sus|add|dom|m|\d+))*?(?:/[A-G](?:#|b)?|/\d+)?\)?(?![A-Za-z0-9])"#

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
        var pendingChordRow: String?
        var untimestampedRows: [String] = []

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
                let chords = pendingChordRow.map {
                    parseChordRow($0, timestampPrefixWidth: timestamped.prefixWidth)
                } ?? []
                pendingChordRow = nil

                if !timestamped.text.isEmpty || !chords.isEmpty {
                    lines.append(LyricsLine(timestamp: timestamped.timestamp, text: timestamped.text, chords: chords))
                }
                continue
            }

            pendingChordRow = line
            untimestampedRows.append(line)
        }

        if lines.contains(where: { $0.timestamp != nil }) {
            return ParsedLyrics(lines: lines, isTimed: true)
        }

        return ParsedLyrics(lines: parseUntimedChordPairs(untimestampedRows), isTimed: false)
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

    private static func parseUntimedChordPairs(_ rows: [String]) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        var index = 0

        while index < rows.count {
            if index + 1 < rows.count {
                let chords = parseChordRow(rows[index], timestampPrefixWidth: 0)
                let lyricText = rows[index + 1].trimmingCharacters(in: .whitespaces)
                if !lyricText.isEmpty || !chords.isEmpty {
                    lines.append(LyricsLine(timestamp: nil, text: lyricText, chords: chords))
                }
                index += 2
            } else {
                let lyricText = rows[index].trimmingCharacters(in: .whitespaces)
                if !lyricText.isEmpty {
                    lines.append(LyricsLine(timestamp: nil, text: lyricText))
                }
                index += 1
            }
        }

        return lines
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

    // In-memory cache keyed by source, track, mode, and stream signature (max ~20 entries).
    private var cache: [String: LyricsState] = [:]
    private let maxCacheSize = 20

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

    private struct LyricsModeResolution: Sendable {
        let state: LyricsState
        let source: LyricsSource
        let isDurable: Bool
    }

    private struct LyricsStreamSignature: Codable, Equatable, Sendable {
        let streamID: String
        let provider: String?
        let codec: String?
        let format: String?
        let file: String?
        let trackDateModified: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case streamID, provider, codec, format, file, trackDateModified
        }

        init(
            streamID: String,
            provider: String?,
            codec: String?,
            format: String?,
            file: String?,
            trackDateModified: TimeInterval?
        ) {
            self.streamID = streamID
            self.provider = provider
            self.codec = codec
            self.format = format
            self.file = file
            self.trackDateModified = trackDateModified
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let stringID = try? values.decode(String.self, forKey: .streamID) {
                streamID = stringID
            } else {
                streamID = String(try values.decode(Int.self, forKey: .streamID))
            }
            provider = try values.decodeIfPresent(String.self, forKey: .provider)
            codec = try values.decodeIfPresent(String.self, forKey: .codec)
            format = try values.decodeIfPresent(String.self, forKey: .format)
            file = try values.decodeIfPresent(String.self, forKey: .file)
            trackDateModified = try values.decodeIfPresent(TimeInterval.self, forKey: .trackDateModified)
        }
    }

    enum PersistentLyricsOutcome: Codable, Sendable, Equatable {
        case content(String)
        case unavailable
    }

    private struct PersistentLyricsCacheEntry: Codable, Sendable, Equatable {
        let outcome: PersistentLyricsOutcome
        let signature: LyricsStreamSignature
        let savedAt: Date
    }

    struct PersistentLyricsArtifactState: Codable, Sendable, Equatable {
        let trackDateModified: TimeInterval?

        func matches(_ dateModified: Date?) -> Bool {
            trackDateModified == dateModified?.timeIntervalSince1970
        }
    }

    // Persistent lyrics cache directory
    private nonisolated static let lyricsCacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Ensemble/LyricsCache", isDirectory: true)
    }()

    public init(syncCoordinator: SyncCoordinator) {
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Public API

    /// Load lyrics for a track. Cancels any in-flight fetch.
    public func loadLyrics(for track: Track) {
        startLyricsLoad(for: track, clearingCache: false)
    }

    /// Force a fresh lyrics fetch for the current track by evicting its durable outcome.
    public func retryLyrics(for track: Track) {
        startLyricsLoad(for: track, clearingCache: true)
    }

    private func startLyricsLoad(for track: Track, clearingCache: Bool) {
        loadTask?.cancel()

        currentLyrics = .loading
        currentLyricsSource = .none
        hasChordLyricsForCurrentTrack = false
        isDisplayingChordLyrics = false
        activeBundle = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            if clearingCache {
                await self.clearCache(
                    forTrackRatingKey: track.id,
                    sourceCompositeKey: track.sourceCompositeKey ?? "local"
                )
                guard !Task.isCancelled else { return }
            }

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
            async let normal = Self.loadOfflineCachedState(for: track, mode: .lyrics)
            async let chords = Self.loadOfflineCachedState(for: track, mode: .chords)
            let cachedNormal = await normal
            let cachedChords = await chords
            if cachedNormal != nil || cachedChords != nil {
                EnsembleLogger.debug("Lyrics: offline, loaded cached sidecar state for track \(track.id)")
                return LyricsBundle(
                    normalState: cachedNormal?.0 ?? .notAvailable,
                    normalSource: cachedNormal?.1 ?? .noApiClient,
                    chordState: cachedChords?.0 ?? .notAvailable,
                    chordSource: cachedChords?.1 ?? .noApiClient
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

        // 2. Fetch normalized track metadata to discover lyrics assets.
        guard let sourceKey = track.sourceCompositeKey,
              let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey) else {
            EnsembleLogger.debug("Lyrics: source has no lyrics provider \(track.sourceCompositeKey ?? "nil")")
            return LyricsBundle(normalState: .notAvailable, normalSource: .noApiClient, chordState: .notAvailable, chordSource: .noApiClient)
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        guard let provider = syncCoordinator.lyricsProvider(for: sourceKey) else {
            return LyricsBundle(normalState: .notAvailable, normalSource: .noApiClient, chordState: .notAvailable, chordSource: .noApiClient)
        }

        do {
            return try await resolveLyrics(track: track, provider: provider)
        } catch {
            if Task.isCancelled {
                return LyricsBundle(normalState: .notAvailable, normalSource: .cancelled, chordState: .notAvailable, chordSource: .cancelled)
            }
            EnsembleLogger.debug("Lyrics: fetch failed for track \(track.id): \(error.localizedDescription)")
            return LyricsBundle(normalState: .notAvailable, normalSource: .trackMetadataFailed, chordState: .notAvailable, chordSource: .trackMetadataFailed)
        }
    }

    private func resolveLyrics(
        track: Track,
        provider: MusicSourceLyricsProviding
    ) async throws -> LyricsBundle {
        if await hasDurableNoAssetsOutcome(for: track) {
            await saveResolvedArtifactState(for: track)
            return Self.noLyricsBundle
        }

        guard let metadata = try await provider.getLyricsMetadata(trackID: track.id) else {
            EnsembleLogger.debug("Lyrics: metadata fetch returned nil for \(track.id)")
            return LyricsBundle(
                normalState: .notAvailable,
                normalSource: .trackMetadataFailed,
                chordState: .notAvailable,
                chordSource: .trackMetadataFailed
            )
        }
        let signatureTrack = Track(
            id: track.id,
            key: track.key,
            title: metadata.title,
            dateModified: metadata.dateModified ?? track.dateModified,
            sourceCompositeKey: track.sourceCompositeKey
        )
        let allAssets = metadata.normalAssets + metadata.chordCandidateAssets
        EnsembleLogger.debug("Lyrics: source returned \(allAssets.count) lyrics assets")
        for asset in allAssets {
            EnsembleLogger.debug(
                "Lyrics: asset id=\(asset.id) codec=\(asset.codec ?? "nil") timed=\(asset.isTimed) provider=\(asset.provider ?? "nil") file=\(asset.file ?? "nil")"
            )
        }

        guard !allAssets.isEmpty else {
            await saveNoAssetsOutcome(for: signatureTrack)
            await saveResolvedArtifactState(for: track)
            return Self.noLyricsBundle
        }

        if metadata.normalAssets.isEmpty {
            await saveNoAssetsOutcome(for: signatureTrack, mode: .lyrics)
        }
        if metadata.chordCandidateAssets.isEmpty {
            await saveNoAssetsOutcome(for: signatureTrack, mode: .chords)
        }

        let normal = await fetchNormalLyrics(
            track: signatureTrack,
            assets: metadata.normalAssets,
            provider: provider
        )
        let chords = await fetchChordLyrics(
            track: signatureTrack,
            assets: metadata.chordCandidateAssets,
            provider: provider
        )
        if normal.isDurable, chords.isDurable {
            await saveResolvedArtifactState(for: track)
        }
        return LyricsBundle(
            normalState: normal.state,
            normalSource: normal.source,
            chordState: chords.state,
            chordSource: chords.source
        )
    }

    private static var noLyricsBundle: LyricsBundle {
        LyricsBundle(
            normalState: .notAvailable,
            normalSource: .noLyricsStream,
            chordState: .notAvailable,
            chordSource: .noLyricsStream
        )
    }

    private func hasDurableNoAssetsOutcome(for track: Track) async -> Bool {
        let signature = Self.noAssetsSignature(for: track)
        async let normal = loadPersistentOutcome(
            key: Self.noAssetsKey(for: track, mode: .lyrics),
            signature: signature,
            mode: .lyrics
        )
        async let chords = loadPersistentOutcome(
            key: Self.noAssetsKey(for: track, mode: .chords),
            signature: signature,
            mode: .chords
        )
        let outcomes = await (normal, chords)
        return outcomes.0 == .unavailable && outcomes.1 == .unavailable
    }

    private func saveNoAssetsOutcome(for track: Track) async {
        await saveNoAssetsOutcome(for: track, mode: .lyrics)
        await saveNoAssetsOutcome(for: track, mode: .chords)
    }

    private func saveNoAssetsOutcome(for track: Track, mode: LyricsMode) async {
        await savePersistentOutcome(
            .unavailable,
            key: Self.noAssetsKey(for: track, mode: mode),
            signature: Self.noAssetsSignature(for: track)
        )
    }

    private func fetchNormalLyrics(
        track: Track,
        assets: [MusicSourceLyricsAsset],
        provider: MusicSourceLyricsProviding
    ) async -> LyricsModeResolution {
        guard !assets.isEmpty else {
            return LyricsModeResolution(state: .notAvailable, source: .noLyricsStream, isDurable: true)
        }

        var lastUnavailableSource: LyricsSource = .noLyricsStream
        var isDurable = true

        for asset in assets {
            let signature = Self.streamSignature(for: track, asset: asset)
            let key = Self.cacheKey(for: track, asset: asset, mode: .lyrics)
            if let cached = loadCachedState(key: key) {
                if cached.isAvailable {
                    return LyricsModeResolution(state: cached, source: .memoryCache, isDurable: true)
                }
                lastUnavailableSource = .contentFetchFailed
                continue
            }
            switch await loadPersistentOutcome(
                key: key,
                signature: signature,
                mode: .lyrics
            ) {
            case .content(let cachedContent):
                if let parsed = Self.parseContent(cachedContent, codec: asset.codec) {
                    let state = LyricsState.available(parsed)
                    setCached(state, forKey: key)
                    EnsembleLogger.debug("Lyrics: loaded normal lyrics from persistent cache (\(parsed.lines.count) lines)")
                    return LyricsModeResolution(state: state, source: .persistentCache, isDurable: true)
                }
                isDurable = false
            case .unavailable:
                setCached(.notAvailable, forKey: key)
                lastUnavailableSource = .contentFetchFailed
                continue
            case nil:
                break
            }

            do {
                let content = try await provider.getLyricsContent(asset: asset, raw: asset.isLocalMedia)
                guard let content else {
                    await savePersistentOutcome(.unavailable, key: key, signature: signature)
                    setCached(.notAvailable, forKey: key)
                    lastUnavailableSource = .contentFetchFailed
                    continue
                }
                guard !Task.isCancelled else {
                    return LyricsModeResolution(state: .notAvailable, source: .cancelled, isDurable: false)
                }
                if asset.isLocalMedia,
                   Self.parseChordContent(content)?.containsChords == true {
                    lastUnavailableSource = .parseFailed
                    isDurable = false
                    continue
                }
                guard let parsed = Self.parseContent(content, codec: asset.codec), !parsed.lines.isEmpty else {
                    lastUnavailableSource = .parseFailed
                    isDurable = false
                    continue
                }
                let state = LyricsState.available(parsed)
                await savePersistentOutcome(.content(content), key: key, signature: signature)
                setCached(state, forKey: key)
                return LyricsModeResolution(state: state, source: .server, isDurable: true)
            } catch {
                if Task.isCancelled {
                    return LyricsModeResolution(state: .notAvailable, source: .cancelled, isDurable: false)
                }
                lastUnavailableSource = .contentFetchFailed
                isDurable = false
                continue
            }
        }

        return LyricsModeResolution(
            state: .notAvailable,
            source: lastUnavailableSource,
            isDurable: isDurable
        )
    }

    private func fetchChordLyrics(
        track: Track,
        assets: [MusicSourceLyricsAsset],
        provider: MusicSourceLyricsProviding
    ) async -> LyricsModeResolution {
        guard !assets.isEmpty else {
            return LyricsModeResolution(state: .notAvailable, source: .noLyricsStream, isDurable: true)
        }

        var isDurable = true
        for asset in assets {
            let signature = Self.streamSignature(for: track, asset: asset)
            let key = Self.cacheKey(for: track, asset: asset, mode: .chords)
            let cachedOutcome = await loadPersistentOutcome(
                key: key,
                signature: signature,
                mode: .chords
            )
            if cachedOutcome == .unavailable {
                setCached(.notAvailable, forKey: key)
                continue
            }

            do {
                guard let content = try await provider.getLyricsContent(asset: asset, raw: true) else {
                    if let cached = await cachedChordState(
                        forKey: key,
                        cachedOutcome: cachedOutcome
                    ) {
                        return LyricsModeResolution(state: cached.0, source: cached.1, isDurable: true)
                    }
                    await savePersistentOutcome(.unavailable, key: key, signature: signature)
                    setCached(.notAvailable, forKey: key)
                    continue
                }
                guard !Task.isCancelled else {
                    return LyricsModeResolution(state: .notAvailable, source: .cancelled, isDurable: false)
                }
                guard let parsed = Self.parseChordContent(content), parsed.containsChords else {
                    EnsembleLogger.debug("Lyrics: fetched chord asset \(asset.id) but content did not parse as chords")
                    isDurable = false
                    continue
                }
                let state = LyricsState.available(parsed)
                await savePersistentOutcome(.content(content), key: key, signature: signature)
                setCached(state, forKey: key)
                return LyricsModeResolution(state: state, source: .server, isDurable: true)
            } catch {
                if Task.isCancelled {
                    return LyricsModeResolution(state: .notAvailable, source: .cancelled, isDurable: false)
                }
                isDurable = false
                if let cached = await cachedChordState(
                    forKey: key,
                    cachedOutcome: cachedOutcome
                ) {
                    return LyricsModeResolution(state: cached.0, source: cached.1, isDurable: false)
                }
                continue
            }
        }

        return LyricsModeResolution(state: .notAvailable, source: .parseFailed, isDurable: isDurable)
    }

    private func cachedChordState(
        forKey key: String,
        cachedOutcome: PersistentLyricsOutcome?
    ) async -> (LyricsState, LyricsSource)? {
        if let cached = loadCachedState(key: key) {
            return cached.isAvailable ? (cached, .memoryCache) : nil
        }
        if case .content(let cachedContent) = cachedOutcome,
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
    public func fetchAndCacheLyrics(for track: Track) async {
        guard await hasResolvedArtifactState(for: track) == false else { return }
        guard let sourceCompositeKey = track.sourceCompositeKey,
              let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceCompositeKey) else {
            return
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        guard let provider = syncCoordinator.lyricsProvider(for: sourceCompositeKey) else { return }

        do {
            _ = try await resolveLyrics(track: track, provider: provider)
        } catch {
            EnsembleLogger.debug(
                "Lyrics: download pre-cache deferred after transient failure for \(track.id): \(error.localizedDescription)"
            )
        }
    }

    private func hasResolvedArtifactState(for track: Track) async -> Bool {
        await Task.detached(priority: .utility) {
            let url = Self.persistentCachePath(key: Self.artifactStateKey(for: track))
            guard let data = try? Data(contentsOf: url),
                  let state = try? JSONDecoder().decode(PersistentLyricsArtifactState.self, from: data) else {
                return false
            }
            return state.matches(track.dateModified)
        }.value
    }

    private func saveResolvedArtifactState(for track: Track) async {
        await Task.detached(priority: .utility) {
            let state = PersistentLyricsArtifactState(
                trackDateModified: track.dateModified?.timeIntervalSince1970
            )
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? FileManager.default.createDirectory(
                at: Self.lyricsCacheDir,
                withIntermediateDirectories: true
            )
            try? data.write(
                to: Self.persistentCachePath(key: Self.artifactStateKey(for: track)),
                options: .atomic
            )
        }.value
    }

    // MARK: - Cache Cleanup

    /// Clear all persistent lyrics caches and in-memory cache.
    /// Called by CacheManager when user clears all library data.
    @discardableResult
    public func clearAllCaches() async -> Int {
        let removedInMemoryCount = cache.count
        cache.removeAll()
        let removedFileCount = await Task.detached(priority: .utility) {
            let count = (try? FileManager.default.contentsOfDirectory(
                atPath: Self.lyricsCacheDir.path
            ).count) ?? 0
            try? FileManager.default.removeItem(at: Self.lyricsCacheDir)
            try? FileManager.default.createDirectory(
                at: Self.lyricsCacheDir,
                withIntermediateDirectories: true
            )
            return count
        }.value
        return removedInMemoryCount + removedFileCount
    }

    /// Clear persistent lyrics cache files for a specific source.
    /// Called when an account or library is removed.
    @discardableResult
    public func clearCache(forSourceCompositeKey sourceKey: String) async -> Int {
        let oldCacheCount = cache.count
        cache = cache.filter { !$0.key.contains(":\(sourceKey):") }
        let removedInMemoryCount = oldCacheCount - cache.count

        let safeSourceKey = sourceKey.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let removedFileCount = await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                atPath: Self.lyricsCacheDir.path
            ) else {
                return 0
            }
            var removedCount = 0
            for file in files where file.contains(safeSourceKey) {
                if (try? FileManager.default.removeItem(
                    at: Self.lyricsCacheDir.appendingPathComponent(file)
                )) != nil {
                    removedCount += 1
                }
            }
            return removedCount
        }.value
        return removedInMemoryCount + removedFileCount
    }

    /// Remove cached lyrics for a single track/source pair.
    public func clearCache(
        forTrackRatingKey ratingKey: String,
        sourceCompositeKey sourceKey: String
    ) async {
        cache = cache.filter { !$0.key.hasPrefix("\(ratingKey):\(sourceKey):") }
        let safePrefix = Self.safeFilename("\(ratingKey):\(sourceKey):")
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                atPath: Self.lyricsCacheDir.path
            ) else {
                return
            }
            for file in files where file.hasPrefix(safePrefix) {
                try? FileManager.default.removeItem(
                    at: Self.lyricsCacheDir.appendingPathComponent(file)
                )
            }
        }.value
    }

    /// Remove caches for multiple source-scoped tracks with one directory scan.
    public func clearCaches(for references: [OfflineTrackReference]) async {
        let uniqueReferences = Array(Set(references))
        guard !uniqueReferences.isEmpty else { return }

        let prefixes = uniqueReferences.map {
            "\($0.trackRatingKey):\($0.trackSourceCompositeKey):"
        }
        cache = cache.filter { key, _ in !prefixes.contains(where: key.hasPrefix) }

        let safePrefixes = prefixes.map(Self.safeFilename)
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                atPath: Self.lyricsCacheDir.path
            ) else {
                return
            }
            for file in files where safePrefixes.contains(where: file.hasPrefix) {
                try? FileManager.default.removeItem(
                    at: Self.lyricsCacheDir.appendingPathComponent(file)
                )
            }
        }.value
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
    ) async -> (LyricsState, LyricsSource)? {
        await Task.detached(priority: .utility) {
            let sourceKey = track.sourceCompositeKey ?? "local"
            let prefix = safeFilename("\(track.id):\(sourceKey):\(mode.rawValue):")
            guard let files = try? FileManager.default.contentsOfDirectory(
                atPath: lyricsCacheDir.path
            ) else {
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
                switch entry.outcome {
                case .unavailable:
                    return (.notAvailable, .noLyricsStream)
                case .content(let content):
                    switch mode {
                    case .lyrics:
                        if let parsed = parseContent(content, codec: entry.signature.codec),
                           !parsed.lines.isEmpty {
                            return (.available(parsed), .persistentCache)
                        }
                    case .chords:
                        if let parsed = parseChordContent(content), parsed.containsChords {
                            return (.available(parsed), .persistentCache)
                        }
                    }
                }
            }

            return nil
        }.value
    }

    private func loadPersistentOutcome(
        key: String,
        signature: LyricsStreamSignature,
        mode: LyricsMode
    ) async -> PersistentLyricsOutcome? {
        await Task.detached(priority: .utility) {
            let url = Self.persistentCachePath(key: key)
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(PersistentLyricsCacheEntry.self, from: data),
                  entry.signature == signature else {
                return nil
            }
            if mode == .chords,
               case .content = entry.outcome,
               Date().timeIntervalSince(entry.savedAt) > 24 * 60 * 60 {
                return nil
            }
            return entry.outcome
        }.value
    }

    private func savePersistentOutcome(
        _ outcome: PersistentLyricsOutcome,
        key: String,
        signature: LyricsStreamSignature
    ) async {
        await Task.detached(priority: .utility) {
            let entry = PersistentLyricsCacheEntry(
                outcome: outcome,
                signature: signature,
                savedAt: Date()
            )
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? FileManager.default.createDirectory(
                at: Self.lyricsCacheDir,
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.persistentCachePath(key: key), options: .atomic)
        }.value
    }

    // MARK: - In-Memory Cache Management

    private nonisolated static func cacheKey(
        for track: Track,
        asset: MusicSourceLyricsAsset,
        mode: LyricsMode
    ) -> String {
        [
            track.id,
            track.sourceCompositeKey ?? "local",
            mode.rawValue,
            asset.id,
            asset.provider ?? "unknown",
            asset.codec ?? "unknown",
            asset.format ?? "unknown",
            asset.file ?? "unknown",
            track.dateModified.map { String($0.timeIntervalSince1970) } ?? "unknown"
        ].joined(separator: ":")
    }

    private nonisolated static func noAssetsKey(for track: Track, mode: LyricsMode) -> String {
        [
            track.id,
            track.sourceCompositeKey ?? "local",
            mode.rawValue,
            "no-assets"
        ].joined(separator: ":")
    }

    private nonisolated static func artifactStateKey(for track: Track) -> String {
        [
            track.id,
            track.sourceCompositeKey ?? "local",
            "artifact-state"
        ].joined(separator: ":")
    }

    private nonisolated static func noAssetsSignature(for track: Track) -> LyricsStreamSignature {
        LyricsStreamSignature(
            streamID: "no-assets",
            provider: nil,
            codec: nil,
            format: nil,
            file: nil,
            trackDateModified: track.dateModified?.timeIntervalSince1970
        )
    }

    private nonisolated static func streamSignature(
        for track: Track,
        asset: MusicSourceLyricsAsset
    ) -> LyricsStreamSignature {
        LyricsStreamSignature(
            streamID: asset.id,
            provider: asset.provider,
            codec: asset.codec,
            format: asset.format,
            file: asset.file,
            trackDateModified: track.dateModified?.timeIntervalSince1970
        )
    }

    private func loadCachedState(key: String) -> LyricsState? {
        cache[key]
    }

    private func setCached(_ state: LyricsState, forKey key: String) {
        cache[key] = state

        // Evict oldest entries if over limit
        if cache.count > maxCacheSize {
            if let firstKey = cache.keys.first {
                cache.removeValue(forKey: firstKey)
            }
        }
    }
}
