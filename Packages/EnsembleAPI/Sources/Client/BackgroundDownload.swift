import CryptoKit
import Foundation

/// Native file transfers while the queue has execution time, with an OS-owned
/// background handoff when that time ends. Files remain owned until installation.
public actor BackgroundDownload {
    public static let sessionIdentifier = "com.videogorl.ensemble.offline-files.v1"
    public static let shared = BackgroundDownload()

    private struct Record: Codable {
        let identity: String
        let url: URL
        let headers: [String: String]
        var cellular: Bool
        var constrained: Bool
        var resumeData: Data?
        var resumeDigest: Data?
        var validator: String?
        var length: Int64?
        var taskID: Int?
        var resumeOffset: Int64?
        var status: Int?
        var responseHeaders: [String: String]?
    }

    private let directory: URL
    private let configuration: URLSessionConfiguration
    private var records: [String: Record] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var waiters: [String: CheckedContinuation<(URL, HTTPURLResponse), Error>] = [:]
    private var progress: [String: @Sendable (Int64, Int64) async -> Void] = [:]
    private var cancelling: Set<String> = []
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var restoration: Task<Void, Never>?
    private var eventsFinished = false
    private var eventWaiters: [CheckedContinuation<Void, Never>] = []
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private lazy var delegate = DownloadDelegate(owner: self, directory: directory)
    private var ownedSession: URLSession?
    private var ownedImmediateSession: URLSession?
    private var immediateSession: URLSession {
        if let ownedImmediateSession { return ownedImmediateSession }
        let config = configuration.identifier == nil ? configuration.copy() as! URLSessionConfiguration : .default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
        ownedImmediateSession = session
        return session
    }
    private var session: URLSession {
        if let ownedSession { return ownedSession }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        ownedSession = session
        return session
    }

    deinit {
        ownedSession?.invalidateAndCancel()
        ownedImmediateSession?.invalidateAndCancel()
    }

    public init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnsembleBackgroundDownloads", isDirectory: true)
        self.configuration = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        self.configuration.isDiscretionary = false
        self.configuration.timeoutIntervalForResource = 7 * 86_400
        self.configuration.httpMaximumConnectionsPerHost = 3
        self.configuration.urlCache = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }

    private func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { await self.load() }
        restoration = task
        await task.value
    }

    private func load() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            var privateDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try privateDirectory.setResourceValues(values)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "json" {
                if let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: file)),
                   file.deletingPathExtension().lastPathComponent == key(record.identity) {
                    records[key(record.identity)] = record
                }
            }
            // The delegate commits a receipt synchronously, before iOS can discard its temporary file.
            // Recover even if the process died before didCompleteWithError or the actor received its callback.
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.pathExtension == "receipt" {
                guard let receipt = try? JSONDecoder().decode(DownloadReceipt.self, from: Data(contentsOf: file)),
                      receipt.key.count == 64, receipt.key.allSatisfy({ $0.isHexDigit }),
                      records[receipt.key]?.taskID == receipt.taskID,
                      let response = HTTPURLResponse(url: receipt.url, statusCode: receipt.status, httpVersion: nil, headerFields: receipt.headers) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                let incoming = file.deletingPathExtension().appendingPathExtension("incoming")
                let retained = FileManager.default.fileExists(atPath: incoming.path) ? incoming : payload(receipt.key)
                await finished(key: receipt.key, taskID: receipt.taskID, file: retained, response: response,
                               offset: receipt.offset, total: receipt.total, error: nil, resumeData: nil)
                try? FileManager.default.removeItem(at: file)
            }
            for task in await session.allTasks {
                guard let task = task as? URLSessionDownloadTask,
                      let key = task.downloadKey, records[key]?.taskID == task.downloadID, tasks[key] == nil else {
                    task.cancel()
                    continue
                }
                tasks[key] = task
            }
        } catch {
            EnsembleLogger.debug("Native download restoration failed domain=\((error as NSError).domain) code=\((error as NSError).code)")
        }
    }

    /// Reattaches live tasks and completed files without network setup. Inactive records need a fresh provider request.
    public func existingFile(
        identity: String, policy: DownloadNetworkPolicy,
        progress: @escaping @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async throws -> (URL, HTTPURLResponse)? {
        await restore()
        let key = key(identity)
        if let completed = try completedFile(key) { return completed }
        guard tasks[key] != nil, let record = records[key] else { return nil }
        var request = URLRequest(url: record.url)
        request.allHTTPHeaderFields = record.headers
        policy.apply(to: &request)
        return try await file(for: request, identity: identity, progress: progress)
    }

    public func file(
        for request: URLRequest, identity: String, legacyIdentity: String? = nil,
        progress: @escaping @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async throws -> (URL, HTTPURLResponse) {
        await restore()
        try Task.checkCancellation()
        let key = key(identity)
        guard request.httpMethod == nil || request.httpMethod == "GET", let url = request.url else {
            throw URLError(.unsupportedURL)
        }
        if let completed = try completedFile(key) { return completed }
        // Drain pre-migration strong-ETag partials once; new transfers are native file tasks.
        if records[key] == nil, let legacyIdentity,
           ResumableDownload.hasRetainedFile(for: request, identity: legacyIdentity) {
            return try await ResumableDownload.file(for: request, identity: legacyIdentity, progress: progress)
        }
        guard waiters[key] == nil, !cancelling.contains(key) else { throw URLError(.resourceUnavailable) }
        // Resume archives contain the original request flags. A policy change must use a fresh request.
        if let old = records[key], old.url != url || old.headers != (request.allHTTPHeaderFields ?? [:])
            || old.cellular != request.allowsCellularAccess || old.constrained != request.allowsConstrainedNetworkAccess {
            await cancel(key)
            records.removeValue(forKey: key)
        }
        // Awaiting a file means the queue has execution time. Do not wait for
        // discretionary daemon scheduling, including restored zero-byte tasks.
        if let task = tasks[key], task.downloadID > 0 { await cancel(key) }
        var record = records[key] ?? Record(identity: identity, url: url, headers: request.allHTTPHeaderFields ?? [:],
                                            cellular: request.allowsCellularAccess, constrained: request.allowsConstrainedNetworkAccess)
        record.cellular = request.allowsCellularAccess
        record.constrained = request.allowsConstrainedNetworkAccess
        try save(record, key: key)
        let task = try makeTask(record: &record, request: request, key: key, immediate: true)
        self.progress[key] = progress
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[key] = continuation
                    task.resume()
                    if Task.isCancelled { Task { await self.cancel(key, taskID: task.downloadID) } }
                }
            } onCancel: {
                Task { await self.cancel(key, taskID: task.downloadID) }
            }
        } catch {
            let invalidRange: Bool
            if case PlexAPIError.httpError(statusCode: 416) = error { invalidRange = true }
            else { invalidRange = (error as? URLError)?.code == .badServerResponse }
            if record.resumeData != nil, !Task.isCancelled, invalidRange {
                EnsembleLogger.debug("Native download rejected resumed response; restarting once without retained bytes")
                return try await file(for: request, identity: identity, progress: progress)
            }
            throw error
        }
    }

    private func makeTask(record: inout Record, request: URLRequest, key: String, immediate: Bool) throws -> URLSessionDownloadTask {
        if let existing = tasks[key] { return existing }
        let session = immediate ? immediateSession : self.session
        let task: URLSessionDownloadTask
        if let data = record.resumeData, record.resumeDigest == Data(SHA256.hash(data: data)),
           (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = request
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = key + (immediate ? ":immediate" : "")
        record.taskID = task.downloadID
        try save(record, key: key)
        tasks[key] = task
        EnsembleLogger.debug("Native download scheduled task=\(task.downloadID) transport=\(immediate ? "immediate" : "background")")
        return task
    }

    /// Stop app-owned waits, retain native resume data, and let the daemon finish
    /// existing transfers without keeping a continued-processing grant alive.
    public func handoffToBackground() async {
        await restore()
        for key in Array(tasks.keys) {
            guard let task = tasks[key], task.downloadID < 0 else { continue }
            await cancel(key)
            guard var record = records[key], record.status == nil else { continue }
            var request = URLRequest(url: record.url)
            request.allHTTPHeaderFields = record.headers
            request.allowsCellularAccess = record.cellular
            request.allowsConstrainedNetworkAccess = record.constrained
            do {
                let backgroundTask = try makeTask(record: &record, request: request, key: key, immediate: false)
                backgroundTask.resume()
            } catch {
                EnsembleLogger.debug("Native download handoff retained for retry domain=\((error as NSError).domain) code=\((error as NSError).code)")
            }
        }
    }

    public func identities() async -> Set<String> {
        await restore()
        return Set(records.values.map(\.identity))
    }

    public func completedIdentities() async -> Set<String> {
        await restore()
        return Set(records.compactMap { key, record in
            FileManager.default.fileExists(atPath: payload(key).path) && record.status != nil ? record.identity : nil
        })
    }

    /// Discard only after installation, invalid media, or authoritative queue removal.
    public func discard(identity: String) async {
        await restore()
        let key = key(identity)
        await cancel(key)
        records.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: payload(key))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json"))
    }

    public func retain(identities: Set<String>) async {
        await restore()
        for identity in records.values.map(\.identity) where !identities.contains(identity) {
            await discard(identity: identity)
        }
    }

    public func pause() async {
        await restore()
        for key in Array(tasks.keys) { await cancel(key) }
    }

    public func finishEvents(identifier: String) async {
        guard identifier == Self.sessionIdentifier else { return }
        await restore()
        if eventsFinished { eventsFinished = false; return }
        await withCheckedContinuation { eventWaiters.append($0) }
    }

    fileprivate func didFinishEvents() {
        eventsFinished = eventWaiters.isEmpty
        eventWaiters.forEach { $0.resume() }
        eventWaiters.removeAll()
    }

    private func cancel(_ key: String, taskID: Int? = nil) async {
        if let taskID, tasks[key]?.downloadID != taskID { return }
        if cancelling.contains(key) {
            await withCheckedContinuation { cancellationWaiters[key, default: []].append($0) }
            return
        }
        guard let task = tasks[key] else { return }
        cancelling.insert(key)
        let data = await withCheckedContinuation { continuation in
            task.cancel { continuation.resume(returning: $0) }
        }
        await finished(key: key, taskID: task.downloadID, file: nil, response: task.response as? HTTPURLResponse,
                       offset: 0, total: task.countOfBytesExpectedToReceive, error: CancellationError(), resumeData: data, cancelled: true)
    }

    fileprivate func resumed(key: String, taskID: Int, offset: Int64) {
        guard var record = records[key], record.taskID == taskID else { return }
        record.resumeOffset = offset
        try? save(record, key: key)
    }

    fileprivate func report(key: String, taskID: Int, received: Int64, expected: Int64) async {
        guard tasks[key]?.downloadID == taskID else { return }
        await progress[key]?(received, expected)
    }

    fileprivate func finished(key: String, taskID: Int, file: URL?, response: HTTPURLResponse?, offset: Int64,
                              total: Int64, error: Error?, resumeData: Data?, cancelled: Bool = false) async {
        defer {
            if let file, file != payload(key) { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(key)-\(taskID).receipt"))
        }
        guard var record = records[key], record.taskID == taskID,
              !cancelling.contains(key) || cancelled else { return }
        defer { cancellationWaiters.removeValue(forKey: key)?.forEach { $0.resume() } }
        record.taskID = nil
        tasks.removeValue(forKey: key)
        cancelling.remove(key)
        progress.removeValue(forKey: key)
        let waiter = waiters.removeValue(forKey: key)
        do {
            if let error {
                record.resumeData = resumeData
                record.resumeDigest = resumeData.map { Data(SHA256.hash(data: $0)) }
                record.validator = response.flatMap(Self.validator) ?? record.validator
                record.length = total > 0 ? total : record.length
                try save(record, key: key)
                EnsembleLogger.debug("Native download interrupted resumable=\(resumeData != nil) domain=\((error as NSError).domain) code=\((error as NSError).code)")
                throw error
            }
            guard let file, let response else { throw URLError(.badServerResponse) }
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            let offset = offset > 0 ? offset : record.resumeOffset ?? 0
            try Self.validate(response: response, size: size, offset: offset, total: total,
                              validator: record.validator, previousLength: record.length)
            if file != payload(key) {
                try? FileManager.default.removeItem(at: payload(key))
                try FileManager.default.moveItem(at: file, to: payload(key))
            }
            record.status = response.statusCode
            record.responseHeaders = response.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) }
            record.resumeData = nil
            record.resumeDigest = nil
            try save(record, key: key)
            EnsembleLogger.debug("Native download completed bytes=\(size) resumedFrom=\(offset) status=\(response.statusCode)")
            if let waiter { waiter.resume(returning: try completedFile(key)!) }
        } catch {
            // Invalid resume state is discarded, allowing the persistent queue's bounded retry to restart cleanly.
            if file != nil || (error as? URLError)?.code == .badServerResponse {
                record.resumeData = nil
                record.resumeDigest = nil
                try? save(record, key: key)
            }
            if error is PlexAPIError {
                records.removeValue(forKey: key)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json"))
            }
            waiter?.resume(throwing: error)
        }
    }

    static func validate(response: HTTPURLResponse, size: Int64, offset: Int64, total: Int64,
                         validator: String?, previousLength: Int64?) throws {
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw PlexAPIError.httpError(statusCode: response.statusCode)
        }
        if response.statusCode == 206 {
            guard offset > 0, size == total, previousLength == total,
                  let validator, Self.validator(response) == validator,
                  ResumableDownload.validContentRange(response.value(forHTTPHeaderField: "Content-Range"), offset: offset, total: total),
                  response.expectedContentLength == total - offset else { throw URLError(.badServerResponse) }
        } else if response.expectedContentLength >= 0, size != response.expectedContentLength {
            throw URLError(.networkConnectionLost)
        }
    }

    private static func validator(_ response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\"") { return etag }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }

    private func completedFile(_ key: String) throws -> (URL, HTTPURLResponse)? {
        guard let record = records[key], let status = record.status,
              FileManager.default.fileExists(atPath: payload(key).path),
              let response = HTTPURLResponse(url: record.url, statusCode: status, httpVersion: nil, headerFields: record.responseHeaders) else { return nil }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // A hard link preserves the receipt through a crash between file installation and database acknowledgment.
        try FileManager.default.linkItem(at: payload(key), to: owned)
        return (owned, response)
    }

    private func save(_ record: Record, key: String) throws {
        let url = directory.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        records[key] = record
    }

    private func payload(_ key: String) -> URL { directory.appendingPathComponent(key + ".media") }
    private func key(_ identity: String) -> String { SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() }
}

private struct DownloadReceipt: Codable {
    let key: String
    let taskID: Int
    let url: URL
    let status: Int
    let headers: [String: String]
    let offset: Int64
    let total: Int64
}

/// URLSession requires synchronous ownership of its temporary file before this callback returns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: BackgroundDownload?
    let directory: URL
    var files: [Int: URL] = [:]
    var errors: [Int: Error] = [:]
    var offsets: [Int: Int64] = [:]
    var totals: [Int: Int64] = [:]
    var lastProgress: [Int: Date] = [:]
    // Serialize actor deliveries so event completion cannot overtake receipt persistence.
    var delivery: Task<Void, Never>?

    init(owner: BackgroundDownload, directory: URL) { self.owner = owner; self.directory = directory }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.downloadID
        guard let key = downloadTask.downloadKey, let response = downloadTask.response as? HTTPURLResponse,
              let url = response.url else { return }
        let destination = directory.appendingPathComponent("\(key)-\(id).incoming")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            let receipt = DownloadReceipt(key: key, taskID: id, url: url, status: response.statusCode,
                headers: response.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) },
                offset: offsets[id] ?? 0, total: totals[id] ?? downloadTask.countOfBytesExpectedToReceive)
            let receiptURL = destination.deletingPathExtension().appendingPathExtension("receipt")
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
            files[id] = destination
        } catch { errors[downloadTask.downloadID] = error }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        offsets[downloadTask.downloadID] = fileOffset
        totals[downloadTask.downloadID] = expectedTotalBytes
        guard let key = downloadTask.downloadKey else { return }
        let previous = delivery
        delivery = Task {
            await previous?.value
            await owner?.resumed(key: key, taskID: downloadTask.downloadID, offset: fileOffset)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.downloadID
        guard Date().timeIntervalSince(lastProgress[id] ?? .distantPast) >= 1, let key = downloadTask.downloadKey else { return }
        lastProgress[id] = Date()
        Task { await owner?.report(key: key, taskID: id, received: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.downloadID
        let file = files.removeValue(forKey: id)
        let failure = errors.removeValue(forKey: id) ?? error
        let offset = offsets.removeValue(forKey: id) ?? 0
        let total = totals.removeValue(forKey: id) ?? task.countOfBytesExpectedToReceive
        lastProgress.removeValue(forKey: id)
        guard let key = task.downloadKey else { return }
        let previous = delivery
        delivery = Task {
            await previous?.value
            await owner?.finished(key: key, taskID: id, file: file, response: task.response as? HTTPURLResponse,
                                  offset: offset, total: total, error: failure,
                                  resumeData: (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let previous = delivery
        delivery = Task { await previous?.value; await owner?.didFinishEvents() }
    }
}

private extension URLSessionTask {
    var downloadKey: String? { taskDescription?.components(separatedBy: ":").first }
    var downloadID: Int { taskDescription?.hasSuffix(":immediate") == true ? -taskIdentifier : taskIdentifier }
}
