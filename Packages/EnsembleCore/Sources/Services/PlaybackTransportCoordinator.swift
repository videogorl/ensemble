import EnsembleAPI
import Foundation

/// A prefetch that did not start because a direct download from the same server is in flight.
/// It is not a failure: the prefetch runs again when that download ends.
struct DirectDownloadBusy: Error {}

/// Owns stream-decision, resolution-task, and prepared-stream state so
/// PlaybackService can delegate transport concerns without owning Plex endpoint details.
final class PlaybackTransportCoordinator {
    /// How long a seek on an original waits for its download before taking an offset transcode.
    /// Thirty seconds, like the stream recovery window: a 50 MB WAV takes about 14 s on the iPhone SE over Wi-Fi.
    var seekWaitLimit: TimeInterval = 30
    struct Dependencies {
        let networkState: @Sendable () async -> NetworkState
        let preparedLocalPlaybackURL: @Sendable (String) -> URL
        let isClearlyInvalidLocalPayload: @Sendable (URL) -> Bool
        let ensureServerConnection: @Sendable (Track) async throws -> Void
        let serverFailureMessage: @Sendable (Track) async -> String?
        let makeStreamDecision: @Sendable (Track, StreamingQuality, TimeInterval, _ forceTranscode: Bool) async throws -> StreamDecision
        let assembleStreamResolution: @Sendable (Track, StreamDecision) async throws -> StreamResolution
        let refreshConnection: @Sendable () async throws -> Void
        let shouldRetryStreamURLRequest: @Sendable (Error) -> Bool
        let mapToPlaybackError: @Sendable (Error) -> PlaybackError
    }

    private let dependencies: Dependencies
    private let streamingQuality: @Sendable () -> String
    private let downloadQuality: @Sendable () -> String
    private let isNetworkConstrained: @Sendable () async -> Bool
    private let allowStreamingOnCellular: @Sendable () -> Bool
    private let artifactCache: PlaybackArtifactCache
    private let streamSessionConfiguration: URLSessionConfiguration?
    private let lock = NSLock()
    private var cachedStreamDecisions: [String: StreamDecision] = [:]
    private var sourceResolutionTasks: [String: Task<PlaybackSource, Error>] = [:]
    private struct PreparedStream {
        let key: PlaybackArtifactKey
        let pipeline: StreamingAudioPipeline
    }
    private var preparedStreams: [String: PreparedStream] = [:]
    /// Tracks whose original was found damaged. They resolve to a forced transcode, a quality below
    /// the original, and never back to the original.
    private var transcodeFallbackTrackIDs: Set<String> = []
    /// Tracks whose fallback decision was taken (for the automation probe).
    private var spentFallbackTrackIDs: Set<String> = []
    /// Plex ends a client's direct download when it requests another direct file, so one
    /// direct download runs per server at a time: the one in flight, by server and track. An
    /// entry without a pipeline is a reservation: a track about to play, or a prefetch being
    /// created, that has claimed the server. Claims are made, and released, under `directLock`
    /// alone, which also keeps a pipeline's end report from deadlocking a cancel under `lock`.
    private let directLock = NSLock()
    private var directDownloads: [String: (trackID: String, pipeline: StreamingAudioPipeline?)] = [:]
    /// Called when a direct download ends, so the prefetch the download deferred can run.
    var onDirectDownloadEnded: (@Sendable () -> Void)?

    init(
        dependencies: Dependencies,
        streamingQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedStreamingQuality() },
        downloadQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedDownloadQuality() },
        isNetworkConstrained: @escaping @Sendable () async -> Bool = { false },
        allowStreamingOnCellular: @escaping @Sendable () -> Bool = {
            AudioQualityPreference.storedAllowStreamingOnCellular()
        },
        artifactCache: PlaybackArtifactCache = .shared,
        streamSessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.streamSessionConfiguration = streamSessionConfiguration
        self.dependencies = dependencies
        self.streamingQuality = streamingQuality
        self.downloadQuality = downloadQuality
        self.isNetworkConstrained = isNetworkConstrained
        self.allowStreamingOnCellular = allowStreamingOnCellular
        self.artifactCache = artifactCache
    }

    func resolvePlaybackSource(for track: Track, startTime: TimeInterval = 0) async throws -> PlaybackSource {
        let trackIdentity = track.playbackIdentity
        let taskKey = sourceResolutionTaskKey(trackIdentity: trackIdentity, startTime: startTime)
        if let existingTask = withLock({ sourceResolutionTasks[taskKey] }) {
            return try await existingTask.value
        }

        let task = Task<PlaybackSource, Error> { [weak self] in
            guard let self else {
                throw PlaybackError.unknown(NSError(domain: "PlaybackTransportCoordinator", code: -1))
            }
            return try await self.resolvePlaybackSourceImpl(for: track, startTime: startTime)
        }
        withLock { sourceResolutionTasks[taskKey] = task }

        do {
            let result = try await task.value
            _ = withLock { sourceResolutionTasks.removeValue(forKey: taskKey) }
            return result
        } catch {
            _ = withLock { sourceResolutionTasks.removeValue(forKey: taskKey) }
            throw error
        }
    }

    func resolveAudioFile(
        for track: Track,
        shouldContinue: @Sendable () async -> Bool = { true }
    ) async throws -> URL {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard await shouldContinue() else { throw CancellationError() }
            do {
                let source = try await resolvePlaybackSource(for: track)
                #if DEBUG
                    if source.fileURL == nil {
                        try await PlaybackAutomationFailure.check(stage: "prefetch", trackID: track.playbackIdentity)
                    }
                #endif
                try Task.checkCancellation()
                guard await shouldContinue() else { throw CancellationError() }
                return try await materializeSourceToFile(source, for: track)
            } catch {
                try Task.checkCancellation()
                guard await shouldContinue() else { throw CancellationError() }
                guard !PlaybackSessionStateMachine.isCancellation(error), !(error is DirectDownloadBusy) else { throw error }
                evict(trackId: track.playbackIdentity, includeDecision: true, cancelTask: true)
                guard attempt == 0,
                      PlaybackSessionStateMachine.isRecoverableNetworkFailure(error) else { throw error }
                EnsembleLogger.debug("[prefetch] Recovering download trackId=\(track.playbackIdentity) attempt=2/2")
                try await dependencies.refreshConnection()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw PlaybackError.streamURLUnavailable
    }

    /// A finished download proved the original damaged while its audio still plays from the good part.
    /// Every later load of the track resolves to the forced transcode; the playing original is left alone.
    func markOriginalDamaged(trackId: String) {
        withLock {
            transcodeFallbackTrackIDs.insert(trackId)
            cachedStreamDecisions.removeValue(forKey: trackId)
        }
    }

    /// The one fallback decision, for a played or a prefetched track: true when `error` says the track's
    /// original is damaged or cannot be streamed. The track then resolves to a forced transcode. The
    /// decision is idempotent, so a prefetch and the played track that adopted its download can both take
    /// it. It cannot loop: only a direct original raises these errors and a fallen-back track never
    /// resolves to one. Network errors, HTTP statuses and a transcode's own failure return false.
    func fallBackToTranscode(after error: Error, trackId: String) -> Bool {
        switch PlaybackSessionStateMachine.underlyingError(error) {
        case ProgressiveStreamError.damagedOriginal, ProgressiveStreamError.unstreamableOriginal: break
        default: return false
        }
        return withLock {
            let isFirst = spentFallbackTrackIDs.insert(trackId).inserted
            transcodeFallbackTrackIDs.insert(trackId)
            if isFirst {
                PlaybackJourneyLogger.mark("originalFallback", trackId: trackId, detail: error.localizedDescription)
                cachedStreamDecisions.removeValue(forKey: trackId)
                preparedStreams.removeValue(forKey: trackId)?.pipeline.cancel()
            }
            return true
        }
    }

    /// For automation: "forced" once a fallback reload was made, "marked" once the damage is known.
    func fallbackStatus(trackId: String) -> String {
        withLock { spentFallbackTrackIDs.contains(trackId) ? "forced" : (transcodeFallbackTrackIDs.contains(trackId) ? "marked" : "") }
    }

    func hasFallenBackToTranscode(trackId: String) -> Bool {
        withLock { transcodeFallbackTrackIDs.contains(trackId) }
    }

    func cancelResolution(for trackId: String) {
        withLock {
            cancelResolutionTasksLocked(for: trackId)
        }
    }

    func evict(trackId: String, includeDecision: Bool, cancelTask: Bool) {
        withLock {
            preparedStreams.removeValue(forKey: trackId)?.pipeline.cancel()
            if includeDecision {
                cachedStreamDecisions.removeValue(forKey: trackId)
            }
            if cancelTask {
                cancelResolutionTasksLocked(for: trackId)
            }
        }
    }

    func clear(removeDecisions: Bool) {
        withLock {
            for stream in preparedStreams.values {
                stream.pipeline.cancel()
            }
            preparedStreams.removeAll()
            for task in sourceResolutionTasks.values {
                task.cancel()
            }
            sourceResolutionTasks.removeAll()
            if removeDecisions {
                cachedStreamDecisions.removeAll()
            }
        }
    }

    func discardPreparedStreams(except trackIDs: Set<String>) {
        withLock {
            for trackID in Array(preparedStreams.keys) where !trackIDs.contains(trackID) {
                preparedStreams.removeValue(forKey: trackID)?.pipeline.cancel()
            }
        }
    }

    func activeLoaderTrackIDs() -> Set<String> {
        withLock { Set(preparedStreams.keys) }
    }

    func cachedDecisionCount() -> Int {
        withLock { cachedStreamDecisions.count }
    }

    private func resolvePlaybackSourceImpl(for track: Track, startTime: TimeInterval) async throws -> PlaybackSource {
        let qualityString = streamingQuality()
        let configuredQuality = StreamingQuality(rawValue: qualityString) ?? .high
        let forcesTranscode = hasFallenBackToTranscode(trackId: track.playbackIdentity)
        // A fallback is never above the configured quality or 320 kbps.
        let quality = forcesTranscode && configuredQuality == .original ? .high : configuredQuality
        let normalizedStartTime = normalizedStartTime(startTime)
        let sourceFingerprint = PlaybackArtifactKey.sourceFingerprint(for: track)

        let networkState = await dependencies.networkState()
        let isDefinitelyOffline = networkState == .offline || networkState == .limited
        let canStream = !isDefinitelyOffline && {
            if case .online(.cellular) = networkState {
                return allowStreamingOnCellular()
            }
            return true
        }()
        let shouldPreferLocalForDataPolicy = await isNetworkConstrained()

        #if DEBUG
        let automation = AutomationLaunchOptions.current
        let forcesNetworkStream = automation.forceNetworkStream
        let ignoresDownloads = forcesNetworkStream || automation.ignoreDownloads
        #else
        let forcesNetworkStream = false
        let ignoresDownloads = false
        #endif

        var localSource: PlaybackSource?
        var hasInvalidLocalPayload = false
        if let localPath = track.localFilePath, !ignoresDownloads {
            if FileManager.default.fileExists(atPath: localPath) {
                let localPlaybackURL = dependencies.preparedLocalPlaybackURL(localPath)
                if !dependencies.isClearlyInvalidLocalPayload(localPlaybackURL) {
                    localSource = .localFile(localPlaybackURL)
                } else if localPlaybackURL.path != localPath {
                    try? FileManager.default.removeItem(at: localPlaybackURL)
                    let originalURL = URL(fileURLWithPath: localPath)
                    if !dependencies.isClearlyInvalidLocalPayload(originalURL) {
                        localSource = .localFile(originalURL)
                    }
                }
                hasInvalidLocalPayload = localSource == nil
            }
        }

        // A seek on an original stays the original: it waits for this track's own direct download, the
        // one request Plex allows, and plays from the verified file. A second direct request would end
        // the download in flight. On a link too slow to finish within `seekWaitLimit`, the seek falls
        // through to the offset transcode rather than leaving the listener in silence.
        if normalizedStartTime > 0, quality == .original,
           let download = inFlightDirectDownload(trackID: track.playbackIdentity),
           let file = try await finishedFile(of: download, within: seekWaitLimit) {
            return .cachedFile(file, origin: .streamCache)
        }
        // A transcode's cached file starts at 0, so an offset transcode is requested instead.
        if normalizedStartTime == 0 || quality == .original, !forcesNetworkStream,
           let cachedURL = artifactCache.completedArtifact(
               trackIdentity: track.playbackIdentity,
               sourceFingerprint: sourceFingerprint,
               requestedQuality: PlaybackArtifactKey.requestedQuality(quality, forcedTranscode: forcesTranscode),
               requireDirect: quality == .original
           ) {
            return .cachedFile(cachedURL, origin: .streamCache)
        }

        if localSource == nil, isDefinitelyOffline {
            if hasInvalidLocalPayload { throw PlaybackError.corruptLocalFile }
            throw PlaybackError.offline
        }

        let prefersStreaming = AudioQualityPreference.prefersStreaming(
            qualityString,
            overDownloadQuality: track.downloadedQuality
                ?? track.localFilePath
                .flatMap { AudioQualityPreference.fileQuality(at: URL(fileURLWithPath: $0)) }
                ?? downloadQuality()
        )
        if let localSource, !canStream || shouldPreferLocalForDataPolicy || !prefersStreaming {
            return localSource
        }
        guard canStream else {
            if hasInvalidLocalPayload { throw PlaybackError.corruptLocalFile }
            if case .online(.cellular) = networkState {
                throw PlaybackError.cellularStreamingDisabled
            }
            throw PlaybackError.offline
        }

        do {
            do {
                try await dependencies.ensureServerConnection(track)
            } catch {
                let failureMessage = await dependencies.serverFailureMessage(track)
                throw PlaybackError.serverUnavailable(message: failureMessage)
            }

            let decision = try await streamDecision(
                for: track,
                quality: quality,
                startTime: normalizedStartTime,
                forceTranscode: forcesTranscode
            )
            let resolution: StreamResolution
            do {
                resolution = try await dependencies.assembleStreamResolution(track, decision)
            } catch {
                throw dependencies.mapToPlaybackError(error)
            }

            do {
                return try await handleStreamResolution(
                    resolution,
                    for: track,
                    quality: quality,
                    forcedTranscode: forcesTranscode,
                    startTime: normalizedStartTime
                )
            } catch {
                guard dependencies.shouldRetryStreamURLRequest(error) else {
                    throw dependencies.mapToPlaybackError(error)
                }
                try await dependencies.refreshConnection()
                let freshResolution = try await dependencies.assembleStreamResolution(track, decision)
                return try await handleStreamResolution(
                    freshResolution,
                    for: track,
                    quality: quality,
                    forcedTranscode: forcesTranscode,
                    startTime: normalizedStartTime
                )
            }
        } catch {
            if let localSource { return localSource }
            throw error
        }
    }

    private func streamDecision(
        for track: Track,
        quality: StreamingQuality,
        startTime: TimeInterval,
        forceTranscode: Bool
    ) async throws -> StreamDecision {
        let trackIdentity = track.playbackIdentity
        // Offset and forced decisions are not cached: the cache holds the track's original decision.
        if startTime > 0 || forceTranscode {
            return try await dependencies.makeStreamDecision(track, quality, startTime, forceTranscode)
        }
        if let cached = withLock({ cachedStreamDecisions[trackIdentity] }) {
            return cached
        }

        do {
            let decision = try await dependencies.makeStreamDecision(track, quality, 0, false)
            withLock { cachedStreamDecisions[trackIdentity] = decision }
            return decision
        } catch {
            if dependencies.shouldRetryStreamURLRequest(error) {
                do {
                    try await dependencies.refreshConnection()
                    let retried = try await dependencies.makeStreamDecision(track, quality, 0, false)
                    withLock { cachedStreamDecisions[trackIdentity] = retried }
                    return retried
                } catch {
                    throw dependencies.mapToPlaybackError(error)
                }
            }
            throw dependencies.mapToPlaybackError(error)
        }
    }

    private func handleStreamResolution(
        _ resolution: StreamResolution,
        for track: Track,
        quality: StreamingQuality,
        forcedTranscode: Bool,
        startTime: TimeInterval
    ) async throws -> PlaybackSource {
        let sourceFingerprint = PlaybackArtifactKey.sourceFingerprint(for: track)
        switch resolution {
        case let .downloadedFile(url):
            return .cachedFile(url, origin: .streamCache)
        case let .directStream(url):
            if url.isFileURL { return .localFile(url) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            return .directHTTP(request, metadata: PlaybackSourceMetadata(
                trackId: track.playbackIdentity,
                ratingKey: track.id,
                estimatedContentLength: nil,
                duration: track.duration,
                startTime: 0,
                isSeekable: true,
                cacheFileExtension: fileExtension,
                artifactKey: PlaybackArtifactKey(
                    trackIdentity: track.playbackIdentity,
                    sourceFingerprint: sourceFingerprint,
                    requestedQuality: PlaybackArtifactKey.requestedQuality(quality, forcedTranscode: forcedTranscode),
                    delivery: .direct,
                    fileExtension: fileExtension,
                    startTime: 0
                ),
                directServerKey: MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey)
            ))
        case let .progressiveTranscode(config):
            return .transcodedHTTP(config.streamRequest, metadata: PlaybackSourceMetadata(
                trackId: track.playbackIdentity,
                ratingKey: config.ratingKey,
                estimatedContentLength: config.estimatedContentLength,
                duration: config.metadataDuration,
                startTime: config.startTime > 0 ? config.startTime : startTime,
                isSeekable: false,
                cacheFileExtension: "mp3",
                artifactKey: PlaybackArtifactKey(
                    trackIdentity: track.playbackIdentity,
                    sourceFingerprint: sourceFingerprint,
                    requestedQuality: PlaybackArtifactKey.requestedQuality(quality, forcedTranscode: forcedTranscode),
                    delivery: .transcode,
                    fileExtension: "mp3",
                    startTime: config.startTime > 0 ? config.startTime : startTime
                )
            ))
        }
    }

    private func sourceResolutionTaskKey(trackIdentity: String, startTime: TimeInterval) -> String {
        let normalized = normalizedStartTime(startTime)
        return normalized > 0 ? "\(trackIdentity)#start=\(Int(normalized))" : trackIdentity
    }

    private func normalizedStartTime(_ startTime: TimeInterval) -> TimeInterval {
        guard startTime.isFinite, startTime > 0 else { return 0 }
        return floor(startTime)
    }

    private func cancelResolutionTasksLocked(for trackId: String) {
        for key in sourceResolutionTasks.keys where key == trackId || key.hasPrefix("\(trackId)#") {
            sourceResolutionTasks[key]?.cancel()
            sourceResolutionTasks.removeValue(forKey: key)
        }
    }

    /// Removes transport ownership before the engine attaches its decoder. Subsequent
    /// prefetch cancellation can only cancel unclaimed streams.
    func takePreparedPipeline(for source: PlaybackSource, trackID: String) -> StreamingAudioPipeline? {
        let metadata: PlaybackSourceMetadata
        switch source {
        case let .directHTTP(_, value), let .transcodedHTTP(_, value): metadata = value
        case .localFile, .cachedFile:
            withLock { preparedStreams.removeValue(forKey: trackID)?.pipeline.cancel() }
            return nil
        }
        guard let key = metadata.artifactKey else { return nil }
        return withLock {
            if let prepared = preparedStreams[metadata.trackId], prepared.key == key {
                preparedStreams.removeValue(forKey: metadata.trackId)
                EnsembleLogger.debug("[prefetch] Adopted stream trackId=\(metadata.trackId) bytes=\(prepared.pipeline.diagnostics().receivedBytes)")
                return prepared.pipeline
            }
            // The track to be played downloads next: it reserves the server, so no prefetch can
            // start a request meanwhile, and a prefetch of another track still downloading, which
            // would end its download, is cancelled. That prefetch is re-evaluated when it can run.
            guard key.delivery == .direct, let serverKey = metadata.directServerKey else { return nil }
            directLock.lock()
            let inFlight = directDownloads[serverKey]
            directDownloads[serverKey] = (metadata.trackId, nil)
            directLock.unlock()
            if let inFlight, inFlight.trackID != metadata.trackId, let pipeline = inFlight.pipeline,
               preparedStreams[inFlight.trackID]?.pipeline === pipeline {
                EnsembleLogger.debug("[prefetch] Cancelled trackId=\(inFlight.trackID): \(metadata.trackId) plays next from the same server")
                preparedStreams.removeValue(forKey: inFlight.trackID)
                pipeline.cancel()
            }
            return nil
        }
    }

    /// The download's verified file, or nil when it is still running after `limit` seconds. The download
    /// itself is left running either way.
    private func finishedFile(of download: StreamingAudioPipeline, within limit: TimeInterval) async throws -> URL? {
        try await withThrowingTaskGroup(of: URL?.self) { group in
            group.addTask { try await download.downloadedFile() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// The direct download of this track that is still running, if any.
    private func inFlightDirectDownload(trackID: String) -> StreamingAudioPipeline? {
        directLock.lock()
        defer { directLock.unlock() }
        return directDownloads.values.first { $0.trackID == trackID }?.pipeline
    }

    /// Records the direct download the engine started for the track being played, against its reservation.
    func registerDirectDownload(_ pipeline: StreamingAudioPipeline, metadata: PlaybackSourceMetadata) {
        guard metadata.artifactKey?.delivery == .direct, let serverKey = metadata.directServerKey else { return }
        trackDirectDownload(pipeline, trackID: metadata.trackId, serverKey: serverKey)
    }

    /// Frees a reservation that no pipeline registered against: the play attempt failed or was
    /// superseded before the engine made its pipeline.
    func releaseDirectReservation(trackID: String) {
        directLock.lock()
        for (serverKey, entry) in directDownloads where entry.pipeline == nil && entry.trackID == trackID {
            directDownloads.removeValue(forKey: serverKey)
        }
        directLock.unlock()
    }

    /// Claims the server for a prefetch unless a download or another claim is already there.
    private func claimDirectDownload(serverKey: String, trackID: String) -> Bool {
        directLock.lock()
        defer { directLock.unlock() }
        guard directDownloads[serverKey] == nil else { return false }
        directDownloads[serverKey] = (trackID, nil)
        return true
    }

    private func trackDirectDownload(_ pipeline: StreamingAudioPipeline, trackID: String, serverKey: String) {
        directLock.lock()
        directDownloads[serverKey] = (trackID, pipeline)
        directLock.unlock()
        pipeline.onDownloadEnd = { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            self.directLock.lock()
            let wasTracked = self.directDownloads[serverKey]?.pipeline === pipeline
            if wasTracked { self.directDownloads.removeValue(forKey: serverKey) }
            self.directLock.unlock()
            if wasTracked { self.onDirectDownloadEnded?() }
        }
    }

    private func materializeSourceToFile(_ source: PlaybackSource, for track: Track) async throws -> URL {
        switch source {
        case let .localFile(url), let .cachedFile(url, _):
            return url
        case let .directHTTP(request, metadata), let .transcodedHTTP(request, metadata):
            guard let key = metadata.artifactKey else { throw PlaybackError.streamURLUnavailable }
            let pipeline = try withLock { () throws -> StreamingAudioPipeline in
                if let existing = preparedStreams[track.playbackIdentity], existing.key == key {
                    return existing.pipeline
                }
                // Do not start a second direct download from a server that has one in flight or reserved.
                let serverKey = key.delivery == .direct ? metadata.directServerKey : nil
                if let serverKey {
                    guard claimDirectDownload(serverKey: serverKey, trackID: track.playbackIdentity) else {
                        throw DirectDownloadBusy()
                    }
                }
                var created = false
                defer { if serverKey != nil, !created { releaseDirectReservation(trackID: track.playbackIdentity) } }
                preparedStreams.removeValue(forKey: track.playbackIdentity)?.pipeline.cancel()
                let pipeline = StreamingAudioPipeline(configuration: .init(
                    request: request,
                    fileExtension: metadata.cacheFileExtension,
                    cacheURL: try artifactCache.partialURL(for: key),
                    duration: metadata.duration,
                    sessionConfiguration: streamSessionConfiguration,
                    trackID: metadata.trackId,
                    artifactKey: key,
                    artifactCache: artifactCache
                ))
                preparedStreams[track.playbackIdentity] = PreparedStream(key: key, pipeline: pipeline)
                if let serverKey {
                    trackDirectDownload(pipeline, trackID: track.playbackIdentity, serverKey: serverKey)
                }
                created = true
                pipeline.startDownload()
                EnsembleLogger.debug("[prefetch] Prepared stream trackId=\(track.playbackIdentity)")
                return pipeline
            }
            // The pipeline registers the validated artifact at network EOF, before
            // waking file consumers or handing completion to active playback.
            // An original is decoded start to end first, so a damaged one raises the damage here.
            return try await pipeline.downloadedFile()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
