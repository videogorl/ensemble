import AVFoundation
import Foundation

final class StreamingAudioPipeline: NSObject {
    struct Configuration {
        let request: URLRequest
        let fileExtension: String
        let cacheURL: URL
        let duration: TimeInterval?
        let bufferSeconds: TimeInterval
        let sessionConfiguration: URLSessionConfiguration

        init(
            request: URLRequest,
            fileExtension: String,
            cacheURL: URL,
            duration: TimeInterval? = nil,
            bufferSeconds: TimeInterval = 20,
            sessionConfiguration: URLSessionConfiguration? = nil
        ) {
            self.request = request
            self.fileExtension = fileExtension
            self.cacheURL = cacheURL
            self.duration = duration
            self.bufferSeconds = bufferSeconds
            self.sessionConfiguration = sessionConfiguration ?? Self.defaultSessionConfiguration()
        }

        private static func defaultSessionConfiguration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.default
            configuration.networkServiceType = .avStreaming
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
    private var cacheHandle: FileHandle?
    private var hasReceivedFirstByte = false
    private var completed = false
    private var cancelled = false
    private var decodedFrameCount: AVAudioFramePosition = 0
    private var decodedFrameTarget: AVAudioFramePosition?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    var isComplete: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completed
    }

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: configuration.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: configuration.cacheURL.path, contents: nil)
            cacheHandle = try FileHandle(forWritingTo: configuration.cacheURL)

            let decoder = try StreamingAudioDecoder(fileExtension: configuration.fileExtension)
            wire(decoder)
            self.decoder = decoder

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration.sessionConfiguration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: configuration.request)
            self.task = task
            task.resume()
        } catch {
            fail(error)
        }
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        pcmBuffer?.wakeWaiters()
        task?.cancel()
        session?.invalidateAndCancel()
        closeCache()
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
            if !hasReceivedFirstByte {
                hasReceivedFirstByte = true
                onFirstByte?()
            }
            try cacheHandle?.write(contentsOf: data)
            try decoder?.append(data)
        } catch {
            fail(error)
        }
    }

    private func complete() {
        stateLock.lock()
        let shouldNotify = !completed
        completed = true
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        pcmBuffer?.wakeWaiters()
        closeCache()
        if shouldNotify {
            onBufferedProgress?(1)
            onComplete?(configuration.cacheURL)
        }
    }

    private func fail(_ error: Error) {
        stateLock.lock()
        cancelled = true
        let pcmBuffer = self.pcmBuffer
        stateLock.unlock()
        pcmBuffer?.wakeWaiters()
        closeCache()
        onFailure?(error)
    }

    private var isActiveForWrites: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !cancelled
    }

    private func closeCache() {
        try? cacheHandle?.close()
        cacheHandle = nil
    }
}

extension StreamingAudioPipeline: URLSessionDataDelegate {
    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
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

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fail(error)
        } else {
            complete()
        }
    }
}
