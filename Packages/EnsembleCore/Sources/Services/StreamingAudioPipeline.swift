import AVFoundation
import Foundation

final class StreamingAudioPipeline: NSObject {
    struct Configuration {
        let request: URLRequest
        let fileExtension: String
        let cacheURL: URL
        let bufferSeconds: TimeInterval
        let sessionConfiguration: URLSessionConfiguration

        init(
            request: URLRequest,
            fileExtension: String,
            cacheURL: URL,
            bufferSeconds: TimeInterval = 20,
            sessionConfiguration: URLSessionConfiguration = .default
        ) {
            self.request = request
            self.fileExtension = fileExtension
            self.cacheURL = cacheURL
            self.bufferSeconds = bufferSeconds
            self.sessionConfiguration = sessionConfiguration
        }
    }

    var onFirstByte: (() -> Void)?
    var onFormatReady: ((AVAudioFormat) -> Void)?
    var onFirstPacket: (() -> Void)?
    var onFirstPCM: (() -> Void)?
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

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    var outputFormat: AVAudioFormat? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pcmBuffer?.format
    }

    var availableFrames: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pcmBuffer?.availableFrames ?? 0
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
                stateLock.lock()
                pcmBuffer = ring
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
            stateLock.unlock()
            do {
                _ = try ring?.write(buffer)
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
        stateLock.unlock()
        closeCache()
        if shouldNotify {
            onComplete?(configuration.cacheURL)
        }
    }

    private func fail(_ error: Error) {
        closeCache()
        onFailure?(error)
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
