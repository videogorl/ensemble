import EnsembleAPI
import Foundation

/// Owns stream-decision, resolution-task, and prepared-stream state so
/// PlaybackService can delegate transport concerns without owning Plex endpoint details.
final class PlaybackTransportCoordinator {
    struct Dependencies {
        let networkState: @Sendable () async -> NetworkState
        let preparedLocalPlaybackURL: @Sendable (String) -> URL
        let isClearlyInvalidLocalPayload: @Sendable (URL) -> Bool
        let ensureServerConnection: @Sendable (Track) async throws -> Void
        let serverFailureMessage: @Sendable (Track) async -> String?
        let makeStreamDecision: @Sendable (Track, StreamingQuality, TimeInterval) async throws -> StreamDecision
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
    private let lock = NSLock()
    private var cachedStreamDecisions: [String: StreamDecision] = [:]
    private var sourceResolutionTasks: [String: Task<PlaybackSource, Error>] = [:]
    private struct PreparedStream {
        let key: PlaybackArtifactKey
        let pipeline: StreamingAudioPipeline
    }
    private var preparedStreams: [String: PreparedStream] = [:]

    init(
        dependencies: Dependencies,
        streamingQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedStreamingQuality() },
        downloadQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedDownloadQuality() },
        isNetworkConstrained: @escaping @Sendable () async -> Bool = { false },
        allowStreamingOnCellular: @escaping @Sendable () -> Bool = {
            AudioQualityPreference.storedAllowStreamingOnCellular()
        },
        artifactCache: PlaybackArtifactCache = .shared
    ) {
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
                guard !PlaybackSessionStateMachine.isCancellation(error) else { throw error }
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
        let quality = StreamingQuality(rawValue: qualityString) ?? .high
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

        var localSource: PlaybackSource?
        var hasInvalidLocalPayload = false
        if let localPath = track.localFilePath {
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

        if normalizedStartTime == 0,
           let cachedURL = artifactCache.completedArtifact(
               trackIdentity: track.playbackIdentity,
               sourceFingerprint: sourceFingerprint,
               requestedQuality: quality.rawValue,
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

            let decision = try await streamDecision(for: track, quality: quality, startTime: normalizedStartTime)
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
                    startTime: normalizedStartTime
                )
            }
        } catch {
            if let localSource { return localSource }
            throw error
        }
    }

    private func streamDecision(for track: Track, quality: StreamingQuality, startTime: TimeInterval) async throws -> StreamDecision {
        let trackIdentity = track.playbackIdentity
        if startTime > 0 {
            return try await dependencies.makeStreamDecision(track, quality, startTime)
        }
        if let cached = withLock({ cachedStreamDecisions[trackIdentity] }) {
            return cached
        }

        do {
            let decision = try await dependencies.makeStreamDecision(track, quality, 0)
            withLock { cachedStreamDecisions[trackIdentity] = decision }
            return decision
        } catch {
            if dependencies.shouldRetryStreamURLRequest(error) {
                do {
                    try await dependencies.refreshConnection()
                    let retried = try await dependencies.makeStreamDecision(track, quality, 0)
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
                    requestedQuality: quality.rawValue,
                    delivery: .direct,
                    fileExtension: fileExtension,
                    startTime: 0
                )
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
                    requestedQuality: quality.rawValue,
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
            guard let prepared = preparedStreams[metadata.trackId], prepared.key == key else { return nil }
            preparedStreams.removeValue(forKey: metadata.trackId)
            EnsembleLogger.debug("[prefetch] Adopted stream trackId=\(metadata.trackId) bytes=\(prepared.pipeline.diagnostics().receivedBytes)")
            return prepared.pipeline
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
                preparedStreams.removeValue(forKey: track.playbackIdentity)?.pipeline.cancel()
                let pipeline = StreamingAudioPipeline(configuration: .init(
                    request: request,
                    fileExtension: metadata.cacheFileExtension,
                    cacheURL: try artifactCache.partialURL(for: key),
                    duration: metadata.duration,
                    trackID: metadata.trackId,
                    artifactKey: key,
                    artifactCache: artifactCache
                ))
                preparedStreams[track.playbackIdentity] = PreparedStream(key: key, pipeline: pipeline)
                pipeline.startDownload()
                EnsembleLogger.debug("[prefetch] Prepared stream trackId=\(track.playbackIdentity)")
                return pipeline
            }
            // The pipeline registers the validated artifact at network EOF, before
            // waking file consumers or handing completion to active playback.
            return try await pipeline.downloadedFile()
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
