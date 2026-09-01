import AVFoundation
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
    private var reachedEOF = false
    private var writerClosed = false

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

    func finish(error: Error? = nil) {
        condition.lock()
        guard !writerClosed else {
            condition.unlock()
            return
        }
        if terminalError == nil {
            terminalError = error
        }
        reachedEOF = error == nil
        try? writer.close()
        writerClosed = true
        condition.broadcast()
        condition.unlock()
    }

    func read(maxLength: Int) throws -> Data? {
        condition.lock()
        while readOffset >= availableByteCount, terminalError == nil, !reachedEOF {
            condition.wait()
        }
        if let terminalError {
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

        init(
            request: URLRequest,
            fileExtension: String,
            cacheURL: URL,
            duration: TimeInterval? = nil,
            bufferSeconds: TimeInterval = 20,
            startupTimeout: TimeInterval = 15,
            sessionConfiguration: URLSessionConfiguration? = nil
        ) {
            self.request = request
            self.fileExtension = fileExtension
            self.cacheURL = cacheURL
            self.duration = duration
            self.bufferSeconds = bufferSeconds
            self.startupTimeout = startupTimeout
            self.sessionConfiguration = sessionConfiguration ?? Self.defaultSessionConfiguration()
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
    private var lastByteUptime: TimeInterval?
    private var lastPCMUptime: TimeInterval?
    private var decodedFrameCount: AVAudioFramePosition = 0
    private var decodedFrameTarget: AVAudioFramePosition?
    private var responseSummary = "none"
    private var metricsSummary = "none"
    private var startupTimeoutWorkItem: DispatchWorkItem?

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
            metricsSummary: metricsSummary
        )
    }

    func start() {
        do {
            let growingFile = try GrowingAudioFile(url: configuration.cacheURL)
            self.growingFile = growingFile

            let decoder = try StreamingAudioDecoder(fileExtension: configuration.fileExtension)
            wire(decoder)
            self.decoder = decoder
            decoderQueue.async { [weak self, weak decoder] in
                self?.decode(growingFile: growingFile, decoder: decoder)
            }

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration.sessionConfiguration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: configuration.request)
            self.task = task
            task.resume()
            let startupTimeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.failStartupIfNeeded()
            }
            self.startupTimeoutWorkItem = startupTimeoutWorkItem
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + configuration.startupTimeout,
                execute: startupTimeoutWorkItem
            )
        } catch {
            fail(error)
        }
    }

    func cancel() {
        stateLock.lock()
        let shouldNotify = !cancelled && !completed
        cancelled = true
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        pcmBuffer?.wakeWaiters()
        task?.cancel()
        session?.invalidateAndCancel()
        growingFile?.finish(error: URLError(.cancelled))
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        if shouldNotify {
            onFailure?(URLError(.cancelled))
        }
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

    @discardableResult
    func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount
    ) -> Int {
        stateLock.lock()
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        guard let pcmBuffer else { return 0 }
        return pcmBuffer.read(into: audioBufferList, frameCount: frameCount)
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

    private func append(_ data: Data) {
        do {
            stateLock.lock()
            let isFirstByte = !hasReceivedFirstByte
            hasReceivedFirstByte = true
            receivedByteCount += Int64(data.count)
            lastByteUptime = ProcessInfo.processInfo.systemUptime
            stateLock.unlock()
            if isFirstByte {
                onFirstByte?()
            }
            try growingFile?.append(data)
        } catch {
            fail(error)
        }
    }

    private func finishNetwork() {
        growingFile?.finish()
    }

    private func decode(growingFile: GrowingAudioFile, decoder: StreamingAudioDecoder?) {
        guard let decoder else { return }
        do {
            while let data = try growingFile.read(maxLength: 64 * 1024) {
                try decoder.append(data)
            }
            completeDecodedStream()
        } catch {
            fail(error)
        }
    }

    private func completeDecodedStream() {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        stateLock.lock()
        let hasFormat = pcmBuffer != nil
        let receivedByteCount = self.receivedByteCount
        let shouldNotify = hasFormat && !completed && !cancelled
        if shouldNotify { completed = true }
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        guard hasFormat else {
            fail(ProgressiveStreamError.invalidPayload(bytesReceived: receivedByteCount))
            return
        }
        pcmBuffer?.wakeWaiters()
        if shouldNotify {
            onBufferedProgress?(1)
            onComplete?(configuration.cacheURL)
        }
    }

    private func fail(_ error: Error) {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        stateLock.lock()
        let shouldNotify = !cancelled && !completed
        cancelled = true
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        pcmBuffer?.wakeWaiters()
        growingFile?.finish(error: error)
        task?.cancel()
        if shouldNotify {
            onFailure?(error)
        }
    }

    private func failStartupIfNeeded() {
        stateLock.lock()
        let shouldFail = pcmBuffer == nil && !cancelled && !completed
        stateLock.unlock()
        guard shouldFail else { return }
        fail(URLError(.timedOut))
        task?.cancel()
    }

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

        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            completionHandler(.cancel)
            fail(ProgressiveStreamError.httpError(statusCode: http.statusCode, bodySnippet: nil))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        append(data)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
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
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fail(error)
        } else {
            finishNetwork()
        }
    }
}
