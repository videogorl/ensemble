import EnsembleAPI
import Foundation

/// Owns stream-decision, resolution-task, and progressive-loader state so
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
    private let lock = NSLock()
    private var cachedStreamDecisions: [String: StreamDecision] = [:]
    private var sourceResolutionTasks: [String: Task<PlaybackSource, Error>] = [:]
    private var streamLoaders: [String: ProgressiveStreamLoader] = [:]

    init(
        dependencies: Dependencies,
        streamingQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedStreamingQuality() },
        downloadQuality: @escaping @Sendable () -> String = { AudioQualityPreference.storedDownloadQuality() }
    ) {
        self.dependencies = dependencies
        self.streamingQuality = streamingQuality
        self.downloadQuality = downloadQuality
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

    func resolveAudioFile(for track: Track) async throws -> URL {
        let source = try await resolvePlaybackSource(for: track)
        return try await materializeSourceToFile(source, for: track)
    }

    func cancelResolution(for trackId: String) {
        withLock {
            cancelResolutionTasksLocked(for: trackId)
        }
    }

    func evict(trackId: String, includeDecision: Bool, cancelTask: Bool) {
        withLock {
            streamLoaders.removeValue(forKey: trackId)?.cancel()
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
            for loader in streamLoaders.values {
                loader.cancel()
            }
            streamLoaders.removeAll()
            for task in sourceResolutionTasks.values {
                task.cancel()
            }
            sourceResolutionTasks.removeAll()
            if removeDecisions {
                cachedStreamDecisions.removeAll()
            }
        }
    }

    func activeLoaderTrackIDs() -> Set<String> {
        withLock { Set(streamLoaders.keys) }
    }

    func activeLoaderFileSize(for trackId: String) -> Int64? {
        withLock {
            guard let loader = streamLoaders[trackId] else { return nil }
            let size = loader.currentFileSize
            return size > 0 ? size : nil
        }
    }

    func cachedDecisionCount() -> Int {
        withLock { cachedStreamDecisions.count }
    }

    private func resolvePlaybackSourceImpl(for track: Track, startTime: TimeInterval) async throws -> PlaybackSource {
        let qualityString = streamingQuality()
        let quality = StreamingQuality(rawValue: qualityString) ?? .high
        let normalizedStartTime = normalizedStartTime(startTime)

        let networkState = await dependencies.networkState()
        let isDefinitelyOffline = networkState == .offline || networkState == .limited

        var localSource: PlaybackSource?
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
                if localSource == nil, isDefinitelyOffline { throw PlaybackError.corruptLocalFile }
            } else if isDefinitelyOffline {
                throw PlaybackError.offline
            }
        } else if isDefinitelyOffline {
            throw PlaybackError.offline
        }

        let prefersStreaming = AudioQualityPreference.prefersStreaming(
            qualityString,
            overDownloadQuality: downloadQuality()
        )
        if let localSource, isDefinitelyOffline || !prefersStreaming {
            return localSource
        }

        do {
            if normalizedStartTime == 0, let completedURL = completedLoaderURLIfAvailable(for: track) {
                return .cachedFile(completedURL, origin: .transcodeCache)
            }

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
                return try await handleStreamResolution(resolution, for: track, startTime: normalizedStartTime)
            } catch {
                guard dependencies.shouldRetryStreamURLRequest(error) else {
                    throw dependencies.mapToPlaybackError(error)
                }
                try await dependencies.refreshConnection()
                let freshResolution = try await dependencies.assembleStreamResolution(track, decision)
                return try await handleStreamResolution(freshResolution, for: track, startTime: normalizedStartTime)
            }
        } catch {
            if let localSource { return localSource }
            throw error
        }
    }

    private func completedLoaderURLIfAvailable(for track: Track) -> URL? {
        let trackIdentity = track.playbackIdentity
        return withLock { () -> URL? in
            guard let loader = streamLoaders[trackIdentity], loader.isDownloadComplete else {
                return nil
            }
            if loader.completionError != nil {
                streamLoaders.removeValue(forKey: trackIdentity)?.cancel()
                cachedStreamDecisions.removeValue(forKey: trackIdentity)
                sourceResolutionTasks.removeValue(forKey: trackIdentity)
                return nil
            }
            return loader.localFileURL
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
        startTime: TimeInterval
    ) async throws -> PlaybackSource {
        switch resolution {
        case let .downloadedFile(url):
            return .cachedFile(url, origin: .streamCache)
        case let .directStream(url):
            if url.isFileURL { return .localFile(url) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            return .directHTTP(request, metadata: PlaybackSourceMetadata(
                trackId: track.playbackIdentity,
                ratingKey: track.id,
                estimatedContentLength: nil,
                duration: track.duration,
                startTime: 0,
                isSeekable: true,
                cacheFileExtension: url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            ))
        case let .progressiveTranscode(config):
            return .transcodedHTTP(config.streamRequest, metadata: PlaybackSourceMetadata(
                trackId: track.playbackIdentity,
                ratingKey: config.ratingKey,
                estimatedContentLength: config.estimatedContentLength,
                duration: config.metadataDuration,
                startTime: config.startTime > 0 ? config.startTime : startTime,
                isSeekable: false,
                cacheFileExtension: "mp3"
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

    private func materializeSourceToFile(_ source: PlaybackSource, for track: Track) async throws -> URL {
        switch source {
        case let .localFile(url), let .cachedFile(url, _):
            return url
        case let .directHTTP(request, metadata):
            guard let url = request.url else { throw PlaybackError.streamURLUnavailable }
            return try await downloadStreamToTempFile(
                url: url,
                trackId: metadata.trackId
            )
        case let .transcodedHTTP(request, metadata):
            return try await startProgressiveDownload(
                for: track,
                request: request,
                ratingKey: metadata.ratingKey ?? track.id,
                estimatedContentLength: metadata.estimatedContentLength ?? 0,
                metadataDuration: metadata.duration
            )
        }
    }

    private func startProgressiveDownload(
        for track: Track,
        request: URLRequest,
        ratingKey: String,
        estimatedContentLength: Int64,
        metadataDuration: Double?
    ) async throws -> URL {
        let trackIdentity = track.playbackIdentity
        if let existing = withLock({ streamLoaders[trackIdentity] }) {
            if existing.isDownloadComplete {
                if let error = existing.completionError { throw error }
                return existing.localFileURL
            }
            return try await waitForDownload(loader: existing)
        }

        let loader = ProgressiveStreamLoader(
            request: request,
            ratingKey: ratingKey,
            cacheIdentity: trackIdentity,
            estimatedContentLength: estimatedContentLength,
            metadataDuration: metadataDuration
        )
        withLock { streamLoaders[trackIdentity] = loader }
        return try await waitForDownload(loader: loader)
    }

    private func waitForDownload(
        loader: ProgressiveStreamLoader
    ) async throws -> URL {
        if loader.isDownloadComplete {
            if let error = loader.completionError { throw error }
            return loader.localFileURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeOnce: (Result<URL, Error>) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let previousComplete = loader.onDownloadComplete
            loader.onDownloadComplete = { fileURL, duration in
                previousComplete?(fileURL, duration)
                resumeOnce(.success(fileURL))
            }
            loader.onDownloadFailed = { error in
                resumeOnce(.failure(error))
            }

            if loader.isDownloadComplete {
                if let error = loader.completionError {
                    resumeOnce(.failure(error))
                } else {
                    resumeOnce(.success(loader.localFileURL))
                }
            }
        }
    }

    private func downloadStreamToTempFile(url: URL, trackId: String) async throws -> URL {
        let cacheDir = PlaybackStreamCacheIdentity.streamCacheDirectory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destURL = cacheDir.appendingPathComponent(
            PlaybackStreamCacheIdentity.fileName(for: trackId, pathExtension: ext)
        )
        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse, !(200 ... 299).contains(httpResponse.statusCode) {
            let snippet = String(data: data.prefix(200), encoding: .utf8)
            throw ProgressiveStreamError.httpError(statusCode: httpResponse.statusCode, bodySnippet: snippet)
        }

        try data.write(to: destURL)
        return destURL
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
