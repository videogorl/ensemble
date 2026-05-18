import EnsembleAPI
import Foundation

/// Owns stream-decision, resolution-task, and progressive-loader state so
/// PlaybackService can delegate transport concerns without changing its API.
final class PlaybackTransportCoordinator {
    struct Dependencies {
        let networkState: @Sendable () async -> NetworkState
        let preparedLocalPlaybackURL: @Sendable (String) -> URL
        let isClearlyInvalidLocalPayload: @Sendable (URL) -> Bool
        let ensureServerConnection: @Sendable (Track) async throws -> Void
        let serverFailureMessage: @Sendable (Track) async -> String?
        let makeStreamDecision: @Sendable (Track, StreamingQuality) async throws -> StreamDecision
        let assembleStreamResolution: @Sendable (Track, StreamDecision) async throws -> StreamResolution
        let refreshConnection: @Sendable () async throws -> Void
        let shouldRetryStreamURLRequest: @Sendable (Error) -> Bool
        let mapToPlaybackError: @Sendable (Error) -> PlaybackError
    }

    private let dependencies: Dependencies
    private let lock = NSLock()
    private var cachedStreamDecisions: [String: StreamDecision] = [:]
    private var fileResolutionTasks: [String: Task<URL, Error>] = [:]
    private var streamLoaders: [String: ProgressiveStreamLoader] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func resolveAudioFile(for track: Track) async throws -> URL {
        let trackIdentity = track.playbackIdentity
        if let existingTask = withLock({ fileResolutionTasks[trackIdentity] }) {
            return try await existingTask.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else {
                throw PlaybackError.unknown(NSError(domain: "PlaybackTransportCoordinator", code: -1))
            }
            return try await self.resolveAudioFileImpl(for: track)
        }
        withLock { fileResolutionTasks[trackIdentity] = task }

        do {
            let result = try await task.value
            _ = withLock { fileResolutionTasks.removeValue(forKey: trackIdentity) }
            return result
        } catch {
            _ = withLock { fileResolutionTasks.removeValue(forKey: trackIdentity) }
            throw error
        }
    }

    func cancelResolution(for trackId: String) {
        withLock {
            fileResolutionTasks[trackId]?.cancel()
            fileResolutionTasks.removeValue(forKey: trackId)
        }
    }

    func evict(trackId: String, includeDecision: Bool, cancelTask: Bool) {
        withLock {
            streamLoaders.removeValue(forKey: trackId)?.cancel()
            if includeDecision {
                cachedStreamDecisions.removeValue(forKey: trackId)
            }
            if cancelTask {
                fileResolutionTasks[trackId]?.cancel()
                fileResolutionTasks.removeValue(forKey: trackId)
            }
        }
    }

    func clear(removeDecisions: Bool) {
        withLock {
            for loader in streamLoaders.values {
                loader.cancel()
            }
            streamLoaders.removeAll()
            for task in fileResolutionTasks.values {
                task.cancel()
            }
            fileResolutionTasks.removeAll()
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

    private func resolveAudioFileImpl(for track: Track) async throws -> URL {
        let qualityString = UserDefaults.standard.string(forKey: "streamingQuality") ?? "high"
        let quality = StreamingQuality(rawValue: qualityString) ?? .high

        let networkState = await dependencies.networkState()
        let isDefinitelyOffline = networkState == .offline || networkState == .limited

        if let localPath = track.localFilePath {
            if FileManager.default.fileExists(atPath: localPath) {
                let localPlaybackURL = dependencies.preparedLocalPlaybackURL(localPath)
                if !dependencies.isClearlyInvalidLocalPayload(localPlaybackURL) {
                    return localPlaybackURL
                }
                if localPlaybackURL.path != localPath {
                    try? FileManager.default.removeItem(at: localPlaybackURL)
                    let originalURL = URL(fileURLWithPath: localPath)
                    if !dependencies.isClearlyInvalidLocalPayload(originalURL) {
                        return originalURL
                    }
                }
                if isDefinitelyOffline { throw PlaybackError.corruptLocalFile }
            } else if isDefinitelyOffline {
                throw PlaybackError.offline
            }
        } else if isDefinitelyOffline {
            throw PlaybackError.offline
        }

        if let completedURL = completedLoaderURLIfAvailable(for: track) {
            return completedURL
        }

        do {
            try await dependencies.ensureServerConnection(track)
        } catch {
            let failureMessage = await dependencies.serverFailureMessage(track)
            throw PlaybackError.serverUnavailable(message: failureMessage)
        }

        let decision = try await streamDecision(for: track, quality: quality)
        let resolution: StreamResolution
        do {
            resolution = try await dependencies.assembleStreamResolution(track, decision)
        } catch {
            throw dependencies.mapToPlaybackError(error)
        }

        do {
            return try await handleStreamResolution(resolution, for: track, quality: quality)
        } catch {
            guard dependencies.shouldRetryStreamURLRequest(error) else {
                throw dependencies.mapToPlaybackError(error)
            }
            try await dependencies.refreshConnection()
            let freshResolution = try await dependencies.assembleStreamResolution(track, decision)
            return try await handleStreamResolution(freshResolution, for: track, quality: quality)
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
                fileResolutionTasks.removeValue(forKey: trackIdentity)
                return nil
            }
            return loader.localFileURL
        }
    }

    private func streamDecision(for track: Track, quality: StreamingQuality) async throws -> StreamDecision {
        let trackIdentity = track.playbackIdentity
        if let cached = withLock({ cachedStreamDecisions[trackIdentity] }) {
            return cached
        }

        do {
            let decision = try await dependencies.makeStreamDecision(track, quality)
            withLock { cachedStreamDecisions[trackIdentity] = decision }
            return decision
        } catch {
            if dependencies.shouldRetryStreamURLRequest(error) {
                do {
                    try await dependencies.refreshConnection()
                    let retried = try await dependencies.makeStreamDecision(track, quality)
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
        quality: StreamingQuality
    ) async throws -> URL {
        switch resolution {
        case let .downloadedFile(url):
            return url
        case let .directStream(url):
            if url.isFileURL { return url }
            return try await downloadStreamToTempFile(url: url, trackId: track.playbackIdentity)
        case let .progressiveTranscode(config):
            return try await startProgressiveDownload(for: track, config: config, quality: quality)
        }
    }

    private func startProgressiveDownload(
        for track: Track,
        config: ProgressiveStreamConfig,
        quality: StreamingQuality
    ) async throws -> URL {
        let trackIdentity = track.playbackIdentity
        if let existing = withLock({ streamLoaders[trackIdentity] }) {
            if existing.isDownloadComplete {
                if let error = existing.completionError { throw error }
                return existing.localFileURL
            }
            return try await waitForDownload(loader: existing, trackId: trackIdentity, quality: quality)
        }

        let loader = ProgressiveStreamLoader(
            request: config.streamRequest,
            ratingKey: config.ratingKey,
            estimatedContentLength: config.estimatedContentLength,
            metadataDuration: config.metadataDuration
        )
        withLock { streamLoaders[trackIdentity] = loader }
        return try await waitForDownload(loader: loader, trackId: trackIdentity, quality: quality)
    }

    private func waitForDownload(
        loader: ProgressiveStreamLoader,
        trackId _: String,
        quality _: StreamingQuality
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
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let safeTrackId = trackId.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let destURL = cacheDir.appendingPathComponent("\(String(safeTrackId))_\(UUID().uuidString.prefix(8)).\(ext)")
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
