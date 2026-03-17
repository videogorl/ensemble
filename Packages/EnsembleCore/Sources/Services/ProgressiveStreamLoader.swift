import AVFoundation
import EnsembleAPI
import Foundation

/// Bridges PMS's chunked transcode stream (`Transfer-Encoding: chunked`, no `Content-Length`)
/// to AVPlayer via `AVAssetResourceLoaderDelegate`. Data is written to a growing temp file
/// and served to AVPlayer as it arrives, giving ~1-2s startup instead of waiting for the
/// full ~5MB download.
///
/// Usage:
/// 1. Create with the pre-built URLRequest and estimated content length.
/// 2. Assign as the delegate on an `AVURLAsset` that uses the `ensemble-transcode://` scheme.
/// 3. The loader starts downloading immediately and feeds data to AVPlayer on demand.
/// 4. When the download finishes, `onDownloadComplete` fires for XING injection + analysis.
final class ProgressiveStreamLoader: NSObject, @unchecked Sendable {

    // MARK: - Custom URL Scheme

    /// The scheme that triggers resource loader delegation instead of CFHTTP.
    static let customScheme = "ensemble-transcode"

    /// Convert an HTTPS URL to the custom scheme for AVAssetResourceLoader interception.
    static func customSchemeURL(from originalURL: URL) -> URL? {
        let string = originalURL.absoluteString
        if string.hasPrefix("https://") {
            return URL(string: string.replacingOccurrences(of: "https://", with: "\(customScheme)://"))
        } else if string.hasPrefix("http://") {
            return URL(string: string.replacingOccurrences(of: "http://", with: "\(customScheme)://"))
        }
        return nil
    }

    // MARK: - Callbacks

    /// Called when the download completes successfully. Parameters: (fileURL, metadataDuration).
    /// Use this for XING header injection and frequency analysis.
    var onDownloadComplete: ((URL, Double?) -> Void)?

    // MARK: - Properties

    /// Serial queue shared by both AVAssetResourceLoader and URLSession delegate callbacks.
    /// Thread safety by design — no concurrent access to mutable state.
    let delegateQueue: DispatchQueue

    private let fileURL: URL
    private var writeHandle: FileHandle?
    private let ratingKey: String
    private let metadataDuration: Double?

    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _isComplete = false
    private var _error: Error?
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []

    private let contentType: String
    private let estimatedContentLength: Int64

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?

    // MARK: - Thread-safe accessors

    private var bytesWritten: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _bytesWritten }
        set { lock.lock(); defer { lock.unlock() }; _bytesWritten = newValue }
    }

    private var isComplete: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isComplete }
        set { lock.lock(); defer { lock.unlock() }; _isComplete = newValue }
    }

    private var downloadError: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _error }
        set { lock.lock(); defer { lock.unlock() }; _error = newValue }
    }

    // MARK: - Lifecycle

    /// Start downloading immediately. The data task runs on `delegateQueue`.
    init(
        request: URLRequest,
        ratingKey: String,
        estimatedContentLength: Int64,
        metadataDuration: Double?
    ) {
        self.ratingKey = ratingKey
        self.estimatedContentLength = estimatedContentLength
        self.metadataDuration = metadataDuration
        self.contentType = "public.mp3"

        // Serial queue for both AVAssetResourceLoader and URLSession delegate
        self.delegateQueue = DispatchQueue(label: "com.ensemble.progressive-stream.\(ratingKey)")

        // Create temp file for progressive writing
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let sessionId = UUID().uuidString.prefix(8)
        self.fileURL = cacheDir.appendingPathComponent("\(ratingKey)_\(sessionId).mp3")

        super.init()

        // Create the file and open for writing
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.writeHandle = FileHandle(forWritingAtPath: fileURL.path)

        // Start the download
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.dataTask = session?.dataTask(with: request)
        dataTask?.resume()

        #if DEBUG
        EnsembleLogger.debug("📡 ProgressiveStreamLoader: started download for \(ratingKey) (est. \(estimatedContentLength) bytes)")
        #endif
    }

    /// Cancel the in-flight download and fail any pending AVPlayer requests.
    func cancel() {
        dataTask?.cancel()
        dataTask = nil
        session?.invalidateAndCancel()
        session = nil

        // Fail pending requests so AVPlayer doesn't hang
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        for request in pending {
            if !request.isFinished && !request.isCancelled {
                request.finishLoading(with: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCancelled
                ))
            }
        }

        writeHandle?.closeFile()
        writeHandle = nil

        #if DEBUG
        EnsembleLogger.debug("📡 ProgressiveStreamLoader: cancelled for \(ratingKey)")
        #endif
    }

    deinit {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        writeHandle?.closeFile()
    }

    // MARK: - Pending Request Fulfillment

    /// Try to serve data for all pending AVPlayer requests from the file on disk.
    private func processPendingRequests() {
        lock.lock()
        var stillPending: [AVAssetResourceLoadingRequest] = []
        let requests = pendingRequests
        lock.unlock()

        for request in requests {
            if request.isFinished || request.isCancelled {
                continue
            }
            if fillRequest(request) {
                request.finishLoading()
            } else {
                stillPending.append(request)
            }
        }

        lock.lock()
        pendingRequests = stillPending
        lock.unlock()
    }

    /// Attempt to fill a loading request's data from the temp file.
    /// Returns `true` if the request is fully satisfied or we're at EOF.
    private func fillRequest(_ loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        // Handle content information request
        if let contentInfo = loadingRequest.contentInformationRequest {
            contentInfo.contentType = contentType
            contentInfo.isByteRangeAccessSupported = false
            contentInfo.contentLength = estimatedContentLength
        }

        // Handle data request
        guard let dataRequest = loadingRequest.dataRequest else {
            // Content-info-only request — done
            return true
        }

        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = Int64(dataRequest.requestedLength)
        let currentOffset = dataRequest.currentOffset

        let written = bytesWritten
        let complete = isComplete

        // How much data we can serve right now
        let availableBytes = written - currentOffset
        if availableBytes <= 0 {
            // No data available yet at this offset
            return complete // If download is done, finish with what we have
        }

        // Read from file at the current offset
        let bytesToRead = min(availableBytes, requestedOffset + requestedLength - currentOffset)
        guard bytesToRead > 0 else {
            return complete
        }

        // Read from the temp file
        guard let readHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            return complete
        }
        defer { readHandle.closeFile() }

        readHandle.seek(toFileOffset: UInt64(currentOffset))
        let data = readHandle.readData(ofLength: Int(bytesToRead))

        if !data.isEmpty {
            dataRequest.respond(with: data)
        }

        // Check if we've served everything requested
        let endOfRequestedData = requestedOffset + requestedLength
        if dataRequest.currentOffset >= endOfRequestedData {
            return true
        }

        // Not fully served — wait for more data (unless download is done)
        return complete
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension ProgressiveStreamLoader: AVAssetResourceLoaderDelegate {

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Try to fill immediately; if not fully served, queue for later
        if fillRequest(loadingRequest) {
            loadingRequest.finishLoading()
            return true
        }

        // If download failed, report the error
        if let error = downloadError {
            loadingRequest.finishLoading(with: error)
            return true
        }

        // Queue for fulfillment when more data arrives
        lock.lock()
        pendingRequests.append(loadingRequest)
        lock.unlock()

        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.lock()
        pendingRequests.removeAll { $0 === loadingRequest }
        lock.unlock()
    }
}

// MARK: - URLSessionDataDelegate

extension ProgressiveStreamLoader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Append to temp file
        writeHandle?.write(data)

        lock.lock()
        _bytesWritten += Int64(data.count)
        lock.unlock()

        // Serve data to any waiting AVPlayer requests
        processPendingRequests()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        writeHandle?.closeFile()
        writeHandle = nil

        if let error = error {
            // Don't log cancellation as an error
            if (error as NSError).code != NSURLErrorCancelled {
                downloadError = error
                #if DEBUG
                EnsembleLogger.debug("📡 ProgressiveStreamLoader: download failed for \(ratingKey): \(error.localizedDescription)")
                #endif
            }
        }

        lock.lock()
        _isComplete = true
        let written = _bytesWritten
        lock.unlock()

        // Fulfill any remaining pending requests with whatever data we have
        processPendingRequests()

        // Notify caller for post-download processing (XING injection, frequency analysis)
        if error == nil {
            #if DEBUG
            EnsembleLogger.debug("📡 ProgressiveStreamLoader: download complete for \(ratingKey) (\(written) bytes)")
            #endif
            onDownloadComplete?(fileURL, metadataDuration)
        }
    }
}
