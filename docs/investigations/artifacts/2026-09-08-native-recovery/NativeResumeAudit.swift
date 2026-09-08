import CryptoKit
import Foundation

private struct NativeAuditFailure: Error {
    let code: Int
    let resumeData: Data?
}

private final class NativeAuditDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var result: (URL, HTTPURLResponse)?
    private var savedResumeData: Data?
    private var ownedSession: URLSession?
    private var didCancel = false
    private let cancelAfter: Int64
    private(set) var resumedAt: Int64 = 0

    init(cancelAfter: Int64 = 0) { self.cancelAfter = cancelAfter }

    func file(_ request: URLRequest, resumeData: Data? = nil, background: Bool = false) async throws -> (URL, HTTPURLResponse) {
        let session: URLSession
        if background {
            let configuration = URLSessionConfiguration.background(withIdentifier: "com.videogorl.ensemble.audit." + UUID().uuidString)
            configuration.isDiscretionary = false
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            ownedSession = session
        } else { session = .shared }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
            if !background { task.delegate = self }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard cancelAfter > 0, totalBytesWritten >= cancelAfter, !didCancel else { return }
        didCancel = true
        downloadTask.cancel { data in
            self.lock.lock(); self.savedResumeData = data; self.lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) { resumedAt = fileOffset }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            result = (destination, response)
        } catch { result = nil }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { ownedSession?.finishTasksAndInvalidate(); ownedSession = nil }
        if let error {
            lock.lock(); let saved = savedResumeData; lock.unlock()
            continuation?.resume(throwing: NativeAuditFailure(code: (error as NSError).code, resumeData: (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data ?? saved))
        } else if let result { continuation?.resume(returning: result) }
        else { continuation?.resume(throwing: URLError(.cannotCreateFile)) }
        continuation = nil
    }
}


private struct ResumeRecord: Codable {
 let data: Data
 let digest: Data
 init(_ data: Data) { self.data = data; digest = Data(SHA256.hash(data: data)) }
 var validatedData: Data? { Data(SHA256.hash(data: data)) == digest ? data : nil }
}

@main struct Audit {
 static func main() async throws {
  let args = CommandLine.arguments
  let request = URLRequest(url: URL(string: args[2])!)
  let saved = URL(fileURLWithPath: args[3])
  if args[1] == "cancel" {
   do { let (file, _) = try await NativeAuditDownload(cancelAfter: 1_000_000).file(request); try? FileManager.default.removeItem(at: file) }
   catch let error as NativeAuditFailure {
    if let data = error.resumeData { try JSONEncoder().encode(ResumeRecord(data)).write(to: saved, options: .atomic); print("resumeDataSaved",data.count) }
    else { print("noResumeData",error.code) }
   }
  } else {
   let task = NativeAuditDownload()
   do {
    let (file, response) = try await task.file(request, resumeData: (try? Data(contentsOf: saved)).flatMap { try? JSONDecoder().decode(ResumeRecord.self, from: $0) }?.validatedData)
    defer { try? FileManager.default.removeItem(at: file) }
    let data = try Data(contentsOf: file)
    if response.statusCode == 206 {
     guard task.resumedAt > 0,
           response.value(forHTTPHeaderField: "Content-Range") == "bytes \(task.resumedAt)-\(data.count - 1)/\(data.count)" else {
      print("rejected malformed range"); return
     }
    } else if response.statusCode != 200 || (response.expectedContentLength >= 0 && response.expectedContentLength != data.count) {
     print("rejected response"); return
    }
    print("status",response.statusCode,"offset",task.resumedAt,"bytes",data.count,"sha256",SHA256.hash(data: data).map {String(format:"%02x",$0)}.joined())
   } catch { print("failed",error) }
  }
 }
}
