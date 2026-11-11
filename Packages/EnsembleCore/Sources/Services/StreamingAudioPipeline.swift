import AVFoundation
import EnsembleAPI
import EnsembleSupport
import Foundation

/// An append-only file with one writer and one independently paced reader.
/// The reader blocks only when it reaches the current end of the file, never in
/// URLSession's delegate queue.
final class GrowingAudioFile {
    private let condition = NSCondition()
    private let writer: FileHandle
    private let reader: FileHandle
    private var availableByteCount: UInt64 = 0
    private var readOffset: UInt64 = 0
    private var terminalError: Error?
    private var earlyEnd: Error?
    private var reachedEOF = false
    private var writerClosed = false
    private var drainsBeforeError = false

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        writer = try FileHandle(forWritingTo: url)
        reader = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? writer.close()
        try? reader.close()
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        if let terminalError { throw terminalError }
        guard !reachedEOF, !writerClosed else { throw CocoaError(.fileWriteUnknown) }
        try writer.write(contentsOf: data)
        availableByteCount += UInt64(data.count)
        condition.signal()
    }

    /// `drainingFirst` lets the reader consume the bytes already written before it sees the error.
    func finish(error: Error? = nil, drainingFirst: Bool = false) {
        condition.lock()
        if terminalError == nil {
            terminalError = error
            drainsBeforeError = drainingFirst
        } else if !drainingFirst {
            drainsBeforeError = false
        }
        reachedEOF = error == nil
        if !writerClosed {
            try? writer.close()
            writerClosed = true
        }
        condition.broadcast()
        condition.unlock()
    }

    func closeWriter() {
        condition.lock()
        if !writerClosed {
            try? writer.close()
            writerClosed = true
        }
        condition.unlock()
    }

    func read(maxLength: Int) throws -> Data? {
        condition.lock()
        while readOffset >= availableByteCount, terminalError == nil, !reachedEOF {
            condition.wait()
        }
        if let terminalError, !(drainsBeforeError && readOffset < availableByteCount) {
            condition.unlock()
            throw terminalError
        }
        if readOffset >= availableByteCount, reachedEOF {
            condition.unlock()
            return nil
        }
        let offset = readOffset
        let count = min(UInt64(maxLength), availableByteCount - readOffset)
        condition.unlock()

        try reader.seek(toOffset: offset)
        let data = try reader.read(upToCount: Int(count)) ?? Data()
        guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }

        condition.lock()
        readOffset += UInt64(data.count)
        condition.unlock()
        return data
    }
}

final class StreamingAudioPipeline: NSObject {
    struct Diagnostics {
        let taskState: URLSessionTask.State?
        let secondsSinceLastByte: TimeInterval?
        let secondsSinceLastPCM: TimeInterval?
        let receivedBytes: Int64
        let taskReceivedBytes: Int64
        let taskExpectedBytes: Int64
        let decodedFrames: AVAudioFramePosition
        let bufferedFrames: Int
        let isComplete: Bool
        let responseSummary: String
        let metricsSummary: String

        var summary: String {
            "task=\(taskStateDescription)"
                + " lastByte=\(ageDescription(secondsSinceLastByte))"
                + " lastPCM=\(ageDescription(secondsSinceLastPCM))"
                + " bytes=\(receivedBytes)"
                + " taskBytes=\(taskReceivedBytes)/\(taskExpectedBytes)"
                + " decodedFrames=\(decodedFrames)"
                + " bufferedFrames=\(bufferedFrames)"
                + " complete=\(isComplete)"
                + " response={\(responseSummary)}"
                + " metrics={\(metricsSummary)}"
        }

        private var taskStateDescription: String {
            switch taskState {
            case .running: return "running"
            case .suspended: return "suspended"
            case .canceling: return "canceling"
            case .completed: return "completed"
            case nil: return "none"
            @unknown default: return "unknown"
            }
        }

        private func ageDescription(_ age: TimeInterval?) -> String {
            age.map { String(format: "%.2fs", $0) } ?? "never"
        }
    }

    struct Configuration {
        let request: URLRequest
        let fileExtension: String
        let cacheURL: URL
        let duration: TimeInterval?
        let bufferSeconds: TimeInterval
        let startupTimeout: TimeInterval
        let sessionConfiguration: URLSessionConfiguration
        let trackID: String?
        let artifactKey: PlaybackArtifactKey?
        let artifactCache: PlaybackArtifactCache
        /// How long a dropped download is resumed before the failure is reported, and the pause between attempts.
        let resumeWindow: TimeInterval
        let resumeRetryInterval: TimeInterval
        /// A download that received bytes this recently is healthy: a path change leaves it alone.
        let healthyWindow: TimeInterval
        let now: () -> TimeInterval

        init(
            request: URLRequest,
            fileExtension: String,
            cacheURL: URL,
            duration: TimeInterval? = nil,
            bufferSeconds: TimeInterval = 20,
            startupTimeout: TimeInterval = 15,
            sessionConfiguration: URLSessionConfiguration? = nil,
            trackID: String? = nil,
            artifactKey: PlaybackArtifactKey? = nil,
            artifactCache: PlaybackArtifactCache = .shared,
            idleTimeout: TimeInterval = 15,
            resumeWindow: TimeInterval = AudioPlaybackEngine.maximumRebufferSeconds,
            resumeRetryInterval: TimeInterval = 1,
            healthyWindow: TimeInterval = 2,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            // A dead connection is given up after `idleTimeout` without data, not URLSession's 60 s.
            var request = request
            request.timeoutInterval = min(request.timeoutInterval, idleTimeout)
            self.resumeWindow = resumeWindow
            self.resumeRetryInterval = resumeRetryInterval
            self.healthyWindow = healthyWindow
            self.now = now
            self.request = request
            self.fileExtension = fileExtension
            self.cacheURL = cacheURL
            self.duration = duration
            self.bufferSeconds = bufferSeconds
            self.startupTimeout = startupTimeout
            self.sessionConfiguration = sessionConfiguration ?? Self.defaultSessionConfiguration()
            self.trackID = trackID
            self.artifactKey = artifactKey
            self.artifactCache = artifactCache
        }

        private static func defaultSessionConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            return configuration
        }
    }

    var onFirstByte: (() -> Void)?
    var onFormatReady: ((AVAudioFormat) -> Void)?
    var onFirstPacket: (() -> Void)?
    var onFirstPCM: (() -> Void)?
    var onBufferedProgress: ((Double) -> Void)?
    var onDownloadComplete: ((URL) -> Void)?
    /// The finished original is damaged while its audio plays. Reported once, so later loads of the
    /// track can resolve to a transcode.
    var onDamageFound: ((Error) -> Void)?
    /// Called once when the download ends, however it ends: complete, failed or cancelled.
    var onDownloadEnd: (() -> Void)?
    var onComplete: ((URL) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let configuration: Configuration
    private let stateLock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var decoder: StreamingAudioDecoder?
    private var pcmBuffer: StreamingPCMBuffer?
    private var growingFile: GrowingAudioFile?
    private let decoderQueue = DispatchQueue(label: "com.ensemble.streamingDecoder", qos: .userInitiated)
    private var hasReceivedFirstByte = false
    private var completed = false
    private var cancelled = false
    private var receivedByteCount: Int64 = 0
    private var payloadPrefix = Data()
    private var lastByteUptime: TimeInterval?
    private var lastPCMUptime: TimeInterval?
    private var decodedFrameCount: AVAudioFramePosition = 0
    private var decodedFrameTarget: AVAudioFramePosition?
    private var responseSummary = "none"
    private var metricsSummary = "none"
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var downloadStarted = false
    private var decoderStarted = false
    private var terminalError: Error?
    private var downloadResult: Result<URL, Error>?
    private var downloadWaiters: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var downloadTimeoutWorkItem: DispatchWorkItem?
    /// What a ranged resume must match: the strong ETag and total length of the first response.
    private var resumeValidator: (etag: String, totalBytes: Int64)?
    /// The offset the current task was asked to resume from; nil for the original request.
    private var resumeOffset: Int64?
    private var resumeWorkItem: DispatchWorkItem?
    private var recoveryStartedAt: TimeInterval?
    private var resumeAttempts = 0
    private var lastResumeRequestAt: TimeInterval?
    /// A path change happened and no bytes have arrived since: a resume that then fails to connect
    /// is not retried, so the service reloads on a freshly selected endpoint.
    private var pathChangedAwaitingBytes = false
    /// Set once the download is given up on while audio is still buffered; `render` reports it
    /// when the PCM reserve runs out, so the engine reloads only after the reserve is played.
    private var deferredError: Error?
    private var drainedFailure: Error?
    private var earlyEnd: Error?
    #if DEBUG
        private var didApplyAutomationNetworkDelay = false
        private var didApplyAutomationDrop = false
        private var automationDropClockStart: TimeInterval?
    #endif

    var cacheURL: URL { configuration.cacheURL }

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    var isComplete: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completed
    }

    /// Set when an original's audio decoded cleanly but ran out far short of the length its own
    /// container states. The stream still completes, so what decoded plays out; the player then
    /// reports this as the failure.
    var earlyEndError: Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return earlyEnd
    }

    var isDownloadComplete: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .success? = downloadResult { return true }
        return false
    }

    func diagnostics(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Diagnostics {
        stateLock.lock()
        let task = self.task
        let pcmBuffer = self.pcmBuffer
        let lastByteUptime = self.lastByteUptime
        let lastPCMUptime = self.lastPCMUptime
        let receivedBytes = receivedByteCount
        let decodedFrames = decodedFrameCount
        let isComplete = completed
        let responseSummary = self.responseSummary
        let metricsSummary = self.metricsSummary
        stateLock.unlock()

        return Diagnostics(
            taskState: task?.state,
            secondsSinceLastByte: lastByteUptime.map { max(0, now - $0) },
            secondsSinceLastPCM: lastPCMUptime.map { max(0, now - $0) },
            receivedBytes: receivedBytes,
            taskReceivedBytes: task?.countOfBytesReceived ?? 0,
            taskExpectedBytes: task?.countOfBytesExpectedToReceive ?? NSURLSessionTransferSizeUnknown,
            decodedFrames: decodedFrames,
            bufferedFrames: pcmBuffer?.availableFrames ?? 0,
            isComplete: isComplete,
            responseSummary: responseSummary,
            metricsSummary: metricsSummary + (pcmBuffer.map { buffer in
                let progress = buffer.renderProgress
                return " renderRequestedFrames=\(progress.consumedFrames + progress.missingFrames) renderMissingFrames=\(progress.missingFrames) sampleRate=\(buffer.format.sampleRate)"
            } ?? "")
        )
    }

    /// Prefetch downloads compressed bytes without allocating a PCM buffer or decoder.
    func startDownload() {
        stateLock.lock()
        guard !downloadStarted, !cancelled else {
            stateLock.unlock()
            return
        }
        downloadStarted = true
        do {
            let growingFile = try GrowingAudioFile(url: configuration.cacheURL)
            self.growingFile = growingFile
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration.sessionConfiguration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: configuration.request)
            self.task = task
            let timeout = DispatchWorkItem { [weak self] in
                self?.failDownloadStartupIfNeeded()
            }
            downloadTimeoutWorkItem = timeout
            stateLock.unlock()
            task.resume()
            EnsembleLogger.debug("[StreamingPipeline] downloadStarted trackId=\(configuration.trackID ?? "unknown")")
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + configuration.startupTimeout,
                execute: timeout
            )
        } catch {
            stateLock.unlock()
            fail(error)
        }
    }

    func start() {
        stateLock.lock()
        let existingError = terminalError
        stateLock.unlock()
        if let existingError {
            onFailure?(existingError)
            return
        }

        startDownload()
        stateLock.lock()
        guard !decoderStarted, !cancelled, let growingFile else {
            let error = terminalError
            stateLock.unlock()
            if let error { onFailure?(error) }
            return
        }
        decoderStarted = true
        do {
            let decoder = try StreamingAudioDecoder(fileExtension: configuration.fileExtension)
            wire(decoder)
            self.decoder = decoder
            let startupTimeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.failStartupIfNeeded()
            }
            self.startupTimeoutWorkItem = startupTimeoutWorkItem
            stateLock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + configuration.startupTimeout,
                execute: startupTimeoutWorkItem
            )
            decoderQueue.async { [weak self, weak decoder] in
                self?.decode(growingFile: growingFile, decoder: decoder)
            }
        } catch {
            stateLock.unlock()
            fail(error)
        }
    }

    func downloadedFile() async throws -> URL {
        let waiterID = UUID()
        try Task.checkCancellation()
        startDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateLock.lock()
                let result: Result<URL, Error>? = Task.isCancelled
                    ? .failure(CancellationError()) : downloadResult
                if let result {
                    stateLock.unlock()
                    continuation.resume(with: result)
                } else {
                    downloadWaiters[waiterID] = continuation
                    stateLock.unlock()
                }
            }
        } onCancel: {
            self.stateLock.lock()
            let waiter = self.downloadWaiters.removeValue(forKey: waiterID)
            self.stateLock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }

    func cancel() {
        fail(URLError(.cancelled))
        session?.invalidateAndCancel()
    }

    @discardableResult
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> Int {
        stateLock.lock()
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        guard let pcmBuffer else {
            buffer.frameLength = min(frameCount, buffer.frameCapacity)
            return 0
        }
        return try pcmBuffer.read(into: buffer, frameCount: frameCount)
    }

    var renderProgress: StreamingPCMBuffer.RenderProgress? {
        stateLock.lock()
        let buffer = pcmBuffer
        stateLock.unlock()
        return buffer?.renderProgress
    }

    @discardableResult
    func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> Int {
        stateLock.lock()
        let pcmBuffer = self.pcmBuffer
        let hasDrainedFailure = drainedFailure != nil
        stateLock.unlock()
        guard let pcmBuffer else { return 0 }
        let read = pcmBuffer.read(into: audioBufferList, frameCount: frameCount,
                                  resumeFrames: Int(pcmBuffer.format.sampleRate), isComplete: isComplete)
        if hasDrainedFailure, read < Int(frameCount) {
            // Reported once: the real-time render thread must not keep posting work.
            stateLock.lock()
            let failure = drainedFailure
            drainedFailure = nil
            stateLock.unlock()
            if let failure {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.fail(failure) }
            }
        }
        return read
    }

    private func wire(_ decoder: StreamingAudioDecoder) {
        decoder.onFormatReady = { [weak self] format in
            guard let self else { return }
            do {
                let capacityFrames = max(
                    AVAudioFrameCount(format.sampleRate * configuration.bufferSeconds),
                    4096
                )
                let ring = try StreamingPCMBuffer(format: format, capacityFrames: Int(capacityFrames))
                let frameTarget = configuration.duration
                    .map { AVAudioFramePosition(max(0, $0 * format.sampleRate)) }
                stateLock.lock()
                pcmBuffer = ring
                decodedFrameTarget = frameTarget
                stateLock.unlock()
                startupTimeoutWorkItem?.cancel()
                startupTimeoutWorkItem = nil
                onFormatReady?(format)
            } catch {
                fail(error)
            }
        }
        decoder.onFirstPacket = { [weak self] in self?.onFirstPacket?() }
        decoder.onFirstPCM = { [weak self] in self?.onFirstPCM?() }
        decoder.onPCMBuffer = { [weak self] buffer in
            guard let self else { return }
            stateLock.lock()
            let ring = pcmBuffer
            lastPCMUptime = ProcessInfo.processInfo.systemUptime
            decodedFrameCount += AVAudioFramePosition(buffer.frameLength)
            let progress = decodedFrameTarget
                .flatMap { $0 > 0 ? Double(self.decodedFrameCount) / Double($0) : nil }
                .map { min(max($0, 0), 1) }
            stateLock.unlock()
            do {
                try ring?.writeBlocking(buffer) { [weak self] in
                    self?.isActiveForWrites == true
                }
                if let progress {
                    onBufferedProgress?(progress)
                }
            } catch {
                fail(error)
            }
        }
    }

    private func append(_ data: Data, from sender: URLSessionTask) {
        do {
            stateLock.lock()
            // Bytes from a task that was replaced by a resume are dropped: the file continues from `receivedByteCount`.
            guard sender === task else {
                stateLock.unlock()
                return
            }
            let isFirstByte = !hasReceivedFirstByte
            hasReceivedFirstByte = true
            receivedByteCount += Int64(data.count)
            if payloadPrefix.count < 64 {
                payloadPrefix.append(data.prefix(64 - payloadPrefix.count))
            }
            lastByteUptime = ProcessInfo.processInfo.systemUptime
            pathChangedAwaitingBytes = false
            let timeout = downloadTimeoutWorkItem
            downloadTimeoutWorkItem = nil
            var recovered: (offset: Int64, attempts: Int, seconds: TimeInterval)?
            if let offset = resumeOffset, let startedAt = recoveryStartedAt {
                recovered = (offset, resumeAttempts, configuration.now() - startedAt)
                recoveryStartedAt = nil
                resumeAttempts = 0
            }
            stateLock.unlock()
            timeout?.cancel()
            if let recovered {
                EnsembleLogger.info("[StreamingPipeline] resumed trackId=\(configuration.trackID ?? "unknown") offset=\(recovered.offset) attempts=\(recovered.attempts) sinceDrop=\(String(format: "%.2fs", recovered.seconds))")
            }
            if isFirstByte {
                onFirstByte?()
            }
            try growingFile?.append(data)
        } catch {
            fail(error)
        }
    }

    private func finishNetwork() {
        stateLock.lock()
        guard downloadResult == nil, !cancelled else {
            stateLock.unlock()
            return
        }
        let receivedByteCount = self.receivedByteCount
        guard receivedByteCount >= 256,
              !EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(
                  payloadPrefix,
                  rejectingServiceUnavailable: true
              ) else {
            stateLock.unlock()
            fail(ProgressiveStreamError.invalidPayload(bytesReceived: receivedByteCount))
            return
        }
        // Close the writer for validation, then expose EOF only after registration succeeds.
        growingFile?.closeWriter()
        if let key = configuration.artifactKey, key.delivery == .direct, key.isCompleteTrack {
            // An original is decoded start to end before it is registered or reported complete. The
            // decoder reads to the end of the file meanwhile, so the audio never waits for the check.
            growingFile?.finish()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let result = Result {
                    try OriginalMediaCheck.verify(at: self.configuration.cacheURL, fileExtension: key.fileExtension) { [weak self] in
                        guard let self else { return false }
                        self.stateLock.lock()
                        defer { self.stateLock.unlock() }
                        return !self.cancelled
                    }
                }
                self.finishMediaCheck(result, receivedByteCount: receivedByteCount)
            }
            stateLock.unlock()
            DispatchQueue.global(qos: .utility).async(execute: work)
            return
        }
        completeDownloadLocked(mediaVerified: false, receivedByteCount: receivedByteCount)
    }

    /// The verified original is registered and reported. A damaged one is never cached. Before the
    /// decoder has started (a prefetch) the download fails with the damage; while it plays, the audio
    /// from the good part keeps playing, the damage is reported for later loads, and the decoder's own
    /// end raises the fallback when it reaches it.
    private func finishMediaCheck(_ result: Result<Void, Error>, receivedByteCount: Int64) {
        stateLock.lock()
        guard downloadResult == nil, !cancelled else {
            stateLock.unlock()
            return
        }
        switch result {
        case .success:
            completeDownloadLocked(mediaVerified: true, receivedByteCount: receivedByteCount)
        case .failure(let error) where error is CancellationError:
            stateLock.unlock()
        case .failure(let error):
            guard decoderStarted else {
                stateLock.unlock()
                fail(error)
                return
            }
            downloadResult = .failure(error)
            let waiters = Array(downloadWaiters.values)
            downloadWaiters.removeAll()
            let timeout = downloadTimeoutWorkItem
            downloadTimeoutWorkItem = nil
            stateLock.unlock()
            timeout?.cancel()
            session?.finishTasksAndInvalidate()
            EnsembleLogger.info("[StreamingPipeline] originalFlagged trackId=\(configuration.trackID ?? "unknown") \(error.localizedDescription)")
            onDamageFound?(error)
            for waiter in waiters { waiter.resume(throwing: error) }
            onDownloadEnd?()
        }
    }

    /// Registers the file, ends the download and reports it. Called with `stateLock` held; releases it.
    private func completeDownloadLocked(mediaVerified: Bool, receivedByteCount: Int64) {
        do {
            if let key = configuration.artifactKey, key.isCompleteTrack {
                try configuration.artifactCache.recordCompleted(
                    fileURL: configuration.cacheURL,
                    key: key,
                    // Library metadata never judges an original; its own media does.
                    expectedDuration: key.delivery == .direct ? nil : configuration.duration,
                    mediaVerified: mediaVerified
                )
            }
        } catch {
            stateLock.unlock()
            fail(error)
            return
        }
        growingFile?.finish()
        downloadResult = .success(configuration.cacheURL)
        let waiters = Array(downloadWaiters.values)
        downloadWaiters.removeAll()
        let timeout = downloadTimeoutWorkItem
        downloadTimeoutWorkItem = nil
        stateLock.unlock()
        timeout?.cancel()
        session?.finishTasksAndInvalidate()
        EnsembleLogger.debug("[StreamingPipeline] downloadComplete trackId=\(configuration.trackID ?? "unknown") bytes=\(receivedByteCount)")
        onDownloadComplete?(configuration.cacheURL)
        for waiter in waiters {
            waiter.resume(returning: configuration.cacheURL)
        }
        onDownloadEnd?()
    }

    private func decode(growingFile: GrowingAudioFile, decoder: StreamingAudioDecoder?) {
        guard let decoder else { return }
        do {
            while let data = try growingFile.read(maxLength: 64 * 1024) {
                try decoder.append(data)
            }
            completeDecodedStream()
        } catch {
            stateLock.lock()
            let deferred = deferredError.map { ($0 as NSError) == (error as NSError) } ?? false
            if deferred { drainedFailure = deferredError }
            stateLock.unlock()
            if !deferred { fail(error) }
        }
    }

    private func completeDecodedStream() {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        let earlyEnd = earlyEndOfDecodedAudio()
        stateLock.lock()
        let discardsArtifact = earlyEnd != nil && hasRegisteredArtifactLocked
        let hasFormat = pcmBuffer != nil
        let receivedByteCount = self.receivedByteCount
        let shouldNotify = hasFormat && !completed && !cancelled
        if shouldNotify {
            completed = true
            self.earlyEnd = earlyEnd
        }
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        if discardsArtifact { configuration.artifactCache.removeArtifact(at: configuration.cacheURL) }
        guard hasFormat else {
            // A complete download that never formed an audio format is not audio.
            fail(configuration.artifactKey?.delivery == .direct
                ? ProgressiveStreamError.damagedOriginal(reason: "no audio format")
                : ProgressiveStreamError.invalidPayload(bytesReceived: receivedByteCount))
            return
        }
        pcmBuffer?.wakeWaiters()
        if shouldNotify, earlyEnd == nil {
            onBufferedProgress?(1)
            onComplete?(configuration.cacheURL)
        }
    }

    /// What decoding an original to its end says about it (see `OriginalMediaCheck`). Library metadata
    /// never judges it, and a stream that starts at an offset is not checked. A transcode is never
    /// checked: it cannot fall back.
    private func earlyEndOfDecodedAudio() -> Error? {
        stateLock.lock()
        let decodedFrames = decodedFrameCount
        let sampleRate = pcmBuffer?.format.sampleRate
        stateLock.unlock()
        guard let key = configuration.artifactKey, key.delivery == .direct, key.isCompleteTrack,
              let sampleRate else { return nil }
        return OriginalMediaCheck.classify(
            decodedFrames: Int64(decodedFrames),
            sampleRate: sampleRate,
            containerSeconds: OriginalMediaCheck.containerSeconds(of: configuration.cacheURL)
        )
    }

    /// Network EOF registered this stream's file for replay. Read with `stateLock` held: a file
    /// whose audio is then rejected must be removed, and registration also happens under the lock.
    private var hasRegisteredArtifactLocked: Bool {
        guard case .success = downloadResult else { return false }
        return configuration.artifactKey?.isCompleteTrack == true
    }

    private func fail(_ error: Error) {
        stateLock.lock()
        // Bytes the decoder rejected are never replayed from the cache. Decided under the lock
        // that stops registration, so a registration racing this failure is still undone.
        // A decoder error counts as media damage only on bytes that could be media: an error page or a
        // tiny body is a bad delivery, a network condition, and keeps the plain failure.
        let couldBeMedia = receivedByteCount >= 256
            && !EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(payloadPrefix, rejectingServiceUnavailable: true)
        let classified = configuration.artifactKey?.delivery == .direct && couldBeMedia
            ? OriginalMediaCheck.classify(decoderError: error) : nil
        let isDamage = classified != nil
        let error: Error = classified
            ?? (configuration.artifactKey?.delivery == .direct && !couldBeMedia && error is StreamingAudioDecoder.DecoderError
                ? ProgressiveStreamError.invalidPayload(bytesReceived: receivedByteCount) : error)
        let discardsArtifact = isDamage && hasRegisteredArtifactLocked
        let shouldNotify = !cancelled && !completed
        cancelled = true
        if terminalError == nil { terminalError = error }
        let endsDownload = downloadResult == nil
        if endsDownload { downloadResult = .failure(error) }
        let waiters = Array(downloadWaiters.values)
        downloadWaiters.removeAll()
        let pcmBuffer = self.pcmBuffer
        let growingFile = self.growingFile
        let task = self.task
        let timeout = startupTimeoutWorkItem
        startupTimeoutWorkItem = nil
        let downloadTimeout = downloadTimeoutWorkItem
        downloadTimeoutWorkItem = nil
        let resumeWork = resumeWorkItem
        resumeWorkItem = nil
        stateLock.unlock()
        if discardsArtifact { configuration.artifactCache.removeArtifact(at: configuration.cacheURL) }
        timeout?.cancel()
        downloadTimeout?.cancel()
        resumeWork?.cancel()
        pcmBuffer?.wakeWaiters()
        growingFile?.finish(error: error)
        task?.cancel()
        session?.invalidateAndCancel()
        PlaybackArtifactCache.removePartial(at: configuration.cacheURL)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        if endsDownload { onDownloadEnd?() }
        if shouldNotify {
            onFailure?(error)
        }
    }

    // MARK: - Resuming a dropped download

    /// A download that ends in an error after bytes arrived. An original-quality file (strong ETag, known
    /// length) is resumed with a `Range` request, paced and bounded by `resumeWindow`; the decoder keeps
    /// reading what is on disk meanwhile. Anything else, or a resume that cannot be proved safe, is given
    /// up on once the buffered audio has played out, so the service reloads from the playhead.
    private func handleNetworkError(_ error: Error, task failedTask: URLSessionTask) {
        stateLock.lock()
        guard failedTask === task, !cancelled, downloadResult == nil, deferredError == nil else {
            stateLock.unlock()
            return
        }
        task = nil
        guard hasReceivedFirstByte else {
            stateLock.unlock()
            fail(error)
            return
        }
        // Every byte arrived and the connection failed afterwards: the file is whole.
        if let validator = resumeValidator, receivedByteCount >= validator.totalBytes {
            stateLock.unlock()
            finishNetwork()
            return
        }
        let now = configuration.now()
        let startedAt = recoveryStartedAt ?? now
        recoveryStartedAt = startedAt
        // After a path change, a resume that cannot connect is not retried against the same endpoint:
        // the service's reload selects a fresh one.
        let resumeFailedAfterPathChange = resumeOffset != nil && pathChangedAwaitingBytes
        guard let validator = resumeValidator, !resumeFailedAfterPathChange,
              now - startedAt < configuration.resumeWindow else {
            stateLock.unlock()
            failAfterDraining(error)
            return
        }
        EnsembleLogger.info("[StreamingPipeline] dropped trackId=\(configuration.trackID ?? "unknown") bytes=\(receivedByteCount)/\(validator.totalBytes) error=\((error as NSError).domain):\((error as NSError).code)")
        scheduleResumeAndUnlock(now: now)
    }

    /// Schedules `beginResume`, paced like the service's reloads: a server that sends a little and drops
    /// must not be hit in a tight loop. Called with the lock held; releases it.
    private func scheduleResumeAndUnlock(now: TimeInterval) {
        let delay = max(0, configuration.resumeRetryInterval - (now - (lastResumeRequestAt ?? -.infinity)))
        let work = DispatchWorkItem { [weak self] in self?.beginResume() }
        resumeWorkItem?.cancel()
        resumeWorkItem = work
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Requests the rest of the file from the byte where the last task stopped.
    private func beginResume() {
        stateLock.lock()
        resumeWorkItem = nil
        // A resume already in flight stays the only request: Plex ends one direct download when another starts.
        guard task == nil, !cancelled, downloadResult == nil, deferredError == nil, let session, resumeValidator != nil else {
            stateLock.unlock()
            return
        }
        let now = configuration.now()
        let offset = receivedByteCount
        recoveryStartedAt = recoveryStartedAt ?? now
        lastResumeRequestAt = now
        resumeAttempts += 1
        var request = configuration.request
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let resumeTask = session.dataTask(with: request)
        task = resumeTask
        resumeOffset = offset
        let attempt = resumeAttempts
        let sinceDrop = now - (recoveryStartedAt ?? now)
        stateLock.unlock()
        resumeTask.resume()
        EnsembleLogger.info("[StreamingPipeline] resumeRequested trackId=\(configuration.trackID ?? "unknown") offset=\(offset) attempt=\(attempt) sinceDrop=\(String(format: "%.2fs", sinceDrop))")
    }

    /// The network path changed: a ranged download that has gone quiet restarts on the new path now,
    /// rather than waiting for its old connection to fail. One that is still receiving is left alone.
    func networkPathChanged() {
        stateLock.lock()
        guard let validator = resumeValidator, !cancelled, downloadResult == nil, deferredError == nil,
              hasReceivedFirstByte, receivedByteCount < validator.totalBytes else {
            stateLock.unlock()
            return
        }
        pathChangedAwaitingBytes = true
        let sinceLastByte = lastByteUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        guard sinceLastByte >= configuration.healthyWindow else {
            stateLock.unlock()
            return
        }
        let oldTask = task
        task = nil
        let now = configuration.now()
        recoveryStartedAt = recoveryStartedAt ?? now
        oldTask?.cancel()
        scheduleResumeAndUnlock(now: now)
    }

    /// Gives up on the download without cutting off audio already on disk or in the PCM reserve.
    /// A failure reported for `failedTask` is dropped if a path change has replaced that task meanwhile.
    private func failAfterDraining(_ error: Error, from failedTask: URLSessionTask? = nil) {
        stateLock.lock()
        if let failedTask, failedTask !== task {
            stateLock.unlock()
            return
        }
        guard decoderStarted, pcmBuffer != nil, !completed, !cancelled else {
            stateLock.unlock()
            fail(error)
            return
        }
        guard deferredError == nil else {
            stateLock.unlock()
            return
        }
        deferredError = error
        let oldTask = task
        task = nil
        let resumeWork = resumeWorkItem
        resumeWorkItem = nil
        let growingFile = self.growingFile
        stateLock.unlock()
        resumeWork?.cancel()
        oldTask?.cancel()
        session?.invalidateAndCancel()
        growingFile?.finish(error: error, drainingFirst: true)
        EnsembleLogger.info("[StreamingPipeline] downloadAbandoned trackId=\(configuration.trackID ?? "unknown") error=\((error as NSError).domain):\((error as NSError).code) reason=reloadAfterBuffer")
    }

    private func failStartupIfNeeded() {
        stateLock.lock()
        let shouldFail = pcmBuffer == nil && !cancelled && !completed
        stateLock.unlock()
        guard shouldFail else { return }
        fail(URLError(.timedOut))
        task?.cancel()
    }

    private func failDownloadStartupIfNeeded() {
        stateLock.lock()
        let shouldFail = !hasReceivedFirstByte && downloadResult == nil && !cancelled
        stateLock.unlock()
        if shouldFail { fail(URLError(.timedOut)) }
    }

    #if DEBUG
        private func delayAutomationNetworkChunkIfNeeded() {
            let environment = ProcessInfo.processInfo.environment
            guard environment["ENSEMBLE_AUTOMATION_MODE"] == "1",
                  let trackID = configuration.trackID,
                  let target = environment["ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK"],
                  !target.isEmpty,
                  trackID == target || trackID.hasSuffix("||" + target),
                  let delay = environment["ENSEMBLE_AUTOMATION_STREAM_DELAY_SECONDS"].flatMap(Double.init),
                  delay.isFinite, delay > 0 else { return }
            stateLock.lock()
            let shouldDelay = hasReceivedFirstByte && !didApplyAutomationNetworkDelay && !cancelled
            if shouldDelay { didApplyAutomationNetworkDelay = true }
            stateLock.unlock()
            guard shouldDelay else { return }
            PlaybackJourneyLogger.mark("injectedStreamChunkDelay", trackId: trackID)
            Thread.sleep(forTimeInterval: min(delay, 20))
        }
    #endif

    #if DEBUG
        /// Ends the connection once, as a network drop would, after N bytes or N seconds of the track's download.
        private func dropAutomationConnectionIfNeeded(_ sender: URLSessionTask) {
            let environment = ProcessInfo.processInfo.environment
            guard environment["ENSEMBLE_AUTOMATION_MODE"] == "1",
                  let trackID = configuration.trackID,
                  let target = environment["ENSEMBLE_AUTOMATION_STREAM_DROP_TRACK"],
                  !target.isEmpty,
                  trackID == target || trackID.hasSuffix("||" + target) else { return }
            let afterBytes = environment["ENSEMBLE_AUTOMATION_STREAM_DROP_AFTER_BYTES"].flatMap(Int64.init) ?? .max
            let afterSeconds = environment["ENSEMBLE_AUTOMATION_STREAM_DROP_AFTER_SECONDS"].flatMap(Double.init) ?? .infinity
            stateLock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            let start = automationDropClockStart ?? now
            automationDropClockStart = start
            let shouldDrop = !didApplyAutomationDrop && !cancelled && sender === task
                && (receivedByteCount >= afterBytes || now - start >= afterSeconds)
            if shouldDrop { didApplyAutomationDrop = true }
            stateLock.unlock()
            guard shouldDrop else { return }
            PlaybackJourneyLogger.mark("injectedStreamDrop", trackId: trackID)
            sender.cancel()
            handleNetworkError(URLError(.networkConnectionLost), task: sender)
        }
    #endif

    private var isActiveForWrites: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !cancelled
    }

    private static func duration(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "n/a" }
        return String(format: "%.3fs", max(0, end.timeIntervalSince(start)))
    }
}

extension StreamingAudioPipeline: URLSessionDataDelegate {
    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let framing: String
        if let http = response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "Transfer-Encoding")?.localizedCaseInsensitiveContains("chunked") == true {
            framing = "chunked"
        } else if response.expectedContentLength != NSURLSessionTransferSizeUnknown {
            framing = "contentLength"
        } else {
            framing = "unknown"
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        stateLock.lock()
        responseSummary = "status=\(statusCode) expectedBytes=\(response.expectedContentLength) framing=\(framing)"
        stateLock.unlock()

        stateLock.lock()
        let isCurrent = dataTask === task
        let resumeOffset = self.resumeOffset
        let validator = resumeValidator
        stateLock.unlock()
        guard isCurrent else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        if let resumeOffset {
            // Plex ignores If-Range, so the resumed bytes are appended only if the ETag and range match.
            guard let http, let validator, statusCode == 206,
                  http.value(forHTTPHeaderField: "ETag") == validator.etag,
                  ResumableDownload.validContentRange(http.value(forHTTPHeaderField: "Content-Range"), offset: resumeOffset, total: validator.totalBytes),
                  response.expectedContentLength == validator.totalBytes - resumeOffset else {
                completionHandler(.cancel)
                failAfterDraining(URLError(.badServerResponse), from: dataTask)
                return
            }
        } else if let http, !(200 ... 299).contains(http.statusCode) {
            completionHandler(.cancel)
            fail(ProgressiveStreamError.httpError(statusCode: http.statusCode, bodySnippet: nil))
            return
        } else if let http, statusCode == 200, framing == "contentLength", response.expectedContentLength > 0,
                  let etag = http.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\""),
                  (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity") == "identity" {
            stateLock.lock()
            resumeValidator = (etag, response.expectedContentLength)
            stateLock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        #if DEBUG
            delayAutomationNetworkChunkIfNeeded()
        #endif
        append(data, from: dataTask)
        #if DEBUG
            dropAutomationConnectionIfNeeded(dataTask)
        #endif
    }

    func urlSession(_: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transaction = metrics.transactionMetrics.last
        var summary = "duration=\(String(format: "%.3fs", metrics.taskInterval.duration))"
            + " redirects=\(metrics.redirectCount)"
            + " transactions=\(metrics.transactionMetrics.count)"
        if let transaction {
            summary += " fetch=\(transaction.resourceFetchType)"
                + " protocol=\(transaction.networkProtocolName ?? "unknown")"
                + " reused=\(transaction.isReusedConnection)"
                + " proxy=\(transaction.isProxyConnection)"
                + " dns=\(Self.duration(transaction.domainLookupStartDate, transaction.domainLookupEndDate))"
                + " connect=\(Self.duration(transaction.connectStartDate, transaction.connectEndDate))"
                + " tls=\(Self.duration(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate))"
                + " ttfb=\(Self.duration(transaction.requestStartDate, transaction.responseStartDate))"
                + " transfer=\(Self.duration(transaction.responseStartDate, transaction.responseEndDate))"
        }
        stateLock.lock()
        metricsSummary = summary
        stateLock.unlock()
        let ranged = task.originalRequest?.value(forHTTPHeaderField: "Range") != nil
        EnsembleLogger.info("[StreamingPipeline] connection trackId=\(configuration.trackID ?? "unknown") ranged=\(ranged) \(summary)")
    }

    func urlSession(_: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let isCurrent = completedTask === task
        // A sized download that ends early without an error is a drop too.
        let shortfall = resumeValidator.map { receivedByteCount < $0.totalBytes } ?? false
        stateLock.unlock()
        guard isCurrent else { return }
        if let error = error ?? (shortfall ? URLError(.networkConnectionLost) : nil) {
            handleNetworkError(error, task: completedTask)
        } else {
            finishNetwork()
        }
    }
}
