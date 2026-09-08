import CryptoKit
import Foundation

/// Retains interrupted HTTP files only when a strong entity validator makes appending safe.
public enum ResumableDownload {
    private struct Partial: Codable {
        let etag: String
        let length: Int64
    }

    private static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnsemblePartialDownloads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ponytail: temporary partials expire after seven days; add indexed eviction if cache pressure warrants it.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-7 * 86_400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return directory
    }()

    public static func file(
        for request: URLRequest,
        session: URLSession = .shared,
        identity: String = "",
        progress: @escaping @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async throws -> (URL, HTTPURLResponse) {
        // Hash credentials as part of identity without persisting the URL or headers.
        let headers = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        let key = SHA256.hash(data: Data((identity + (request.url?.absoluteString ?? "") + headers).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let partialURL = directory.appendingPathComponent(key + ".partial")
        let metadataURL = directory.appendingPathComponent(key + ".json")
        var partial = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Partial.self, from: $0) }
        var offset = ((try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if partial == nil || offset <= 0 || offset >= (partial?.length ?? 0) {
            partial = nil
            offset = 0
        }

        var rangedRequest = request
        rangedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let partial, offset > 0 {
            rangedRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            rangedRequest.setValue(partial.etag, forHTTPHeaderField: "If-Range")
        }
        var (bytes, response) = try await session.bytes(for: rangedRequest)
        if (response as? HTTPURLResponse)?.statusCode == 416, offset > 0 {
            bytes.task.cancel()
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: metadataURL)
            partial = nil
            offset = 0
            rangedRequest.setValue(nil, forHTTPHeaderField: "Range")
            rangedRequest.setValue(nil, forHTTPHeaderField: "If-Range")
            (bytes, response) = try await session.bytes(for: rangedRequest)
        }
        let transferTask = bytes.task
        defer { transferTask.cancel() }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw PlexAPIError.httpError(statusCode: response.statusCode)
        }
        let length: Int64
        if response.statusCode == 206 {
            guard let partial, offset > 0,
                  response.value(forHTTPHeaderField: "ETag") == partial.etag,
                  validContentRange(response.value(forHTTPHeaderField: "Content-Range"), offset: offset, total: partial.length),
                  response.expectedContentLength == partial.length - offset else {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw URLError(.badServerResponse)
            }
            length = partial.length
        } else {
            offset = 0 // A changed resource or a server ignoring Range must replace, never append.
            length = response.expectedContentLength
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        let etag = response.value(forHTTPHeaderField: "ETag")
        let canResume = length > 0 && etag?.hasPrefix("\"") == true && etag?.hasSuffix("\"") == true
        if canResume, let etag {
            try JSONEncoder().encode(Partial(etag: etag, length: length)).write(to: metadataURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: metadataURL)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var received = offset
        do {
            try await withTaskCancellationHandler {
                var buffer = Data()
                var lastProgress = Date.distantPast
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= 65_536 {
                        try handle.write(contentsOf: buffer)
                        received += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)
                        if Date().timeIntervalSince(lastProgress) >= 1 {
                            await progress(received, length)
                            lastProgress = Date()
                        }
                    }
                }
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                if length > 0, received != length {
                    EnsembleLogger.debug("Download transfer length mismatch received=\(received) expected=\(length)")
                    throw URLError(.networkConnectionLost)
                }
                await progress(received, length)
            } onCancel: {
                transferTask.cancel()
            }
            let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: partialURL, to: result)
            try? FileManager.default.removeItem(at: metadataURL)
            EnsembleLogger.debug("Download transfer completed bytes=\(received) resumedFrom=\(offset) status=\(response.statusCode)")
            return (result, response)
        } catch {
            EnsembleLogger.debug("Download transfer interrupted status=\(response.statusCode) retained=\(received) expected=\(length) resumedFrom=\(offset) errorDomain=\((error as NSError).domain) errorCode=\((error as NSError).code) cancelled=\(Task.isCancelled)")
            if !canResume {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: metadataURL)
            }
            throw error
        }
    }

    static func validContentRange(_ value: String?, offset: Int64, total: Int64) -> Bool {
        value == "bytes \(offset)-\(total - 1)/\(total)"
    }
}
