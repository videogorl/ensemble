import Foundation
import XCTest
@testable import EnsembleAPI

final class ResumableDownloadTests: XCTestCase {
    private final class Transport: URLProtocol {
        static let payload = Data(repeating: 42, count: 262_144)
        static let lock = NSLock()
        static var attempts = 0
        static var ranges: [String?] = []
        static var replace = false
        static var malformedRange = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        private var failure: DispatchWorkItem?

        override func startLoading() {
            Self.lock.lock()
            Self.attempts += 1
            let attempt = Self.attempts
            Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
            let replace = Self.replace
            let malformedRange = Self.malformedRange
            Self.lock.unlock()
            let offset = Int(request.value(forHTTPHeaderField: "Range")?.dropFirst(6).dropLast() ?? "0") ?? 0
            let append = offset > 0 && !replace
            let data = replace && attempt > 1 ? Data(repeating: 99, count: Self.payload.count) : Self.payload
            var headers = ["ETag": replace && attempt > 1 ? "\"new\"" : "\"original\"", "Content-Length": String(data.count - (append ? offset : 0))]
            if append { headers["Content-Range"] = "bytes \(malformedRange ? offset + 1 : offset)-\(data.count - 1)/\(data.count)" }
            let response = HTTPURLResponse(url: request.url!, statusCode: append ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if attempt == 1 {
                client?.urlProtocol(self, didLoad: data.prefix(131_072))
                let failure = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
                self.failure = failure
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1, execute: failure)
            } else {
                client?.urlProtocol(self, didLoad: data.dropFirst(append ? offset : 0))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() { failure?.cancel() }
    }

    func testInterruptedTransferResumesOrReplacesWithoutCorruptingTheFile() async throws {
        for (replace, cancel, malformed) in [(false, false, false), (true, false, false), (false, true, false), (false, false, true)] {
            Transport.lock.lock()
            Transport.attempts = 0
            Transport.ranges = []
            Transport.replace = replace
            Transport.malformedRange = malformed
            Transport.lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [Transport.self]
            var session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let request = URLRequest(url: URL(string: "https://download.invalid/\(UUID().uuidString)")!)
            let progress = expectation(description: "partial bytes written")
            progress.assertForOverFulfill = false
            let transfer = Task {
                try await ResumableDownload.file(for: request, session: session) { _, _ in progress.fulfill() }
            }
            await fulfillment(of: [progress], timeout: 2)
            if cancel { transfer.cancel() }
            do {
                _ = try await transfer.value
                XCTFail("Expected interrupted transfer")
            } catch {
                if !cancel { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            }
            // Recreate the transport as on relaunch; retained bytes are disk-owned.
            session.invalidateAndCancel()
            session = URLSession(configuration: config)
            if malformed {
                do {
                    _ = try await ResumableDownload.file(for: request, session: session)
                    XCTFail("Must reject a mismatched range")
                } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
                continue
            }
            let (file, _) = try await ResumableDownload.file(for: request, session: session)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try Data(contentsOf: file), replace ? Data(repeating: 99, count: Transport.payload.count) : Transport.payload)
            let ranges = Transport.ranges.compactMap { $0 }
            XCTAssertEqual(ranges.count, 1)
            let offset = Int(ranges.first?.dropFirst(6).dropLast() ?? "0") ?? 0
            XCTAssertGreaterThanOrEqual(offset, 65_536)
            XCTAssertLessThanOrEqual(offset, 131_072)
        }
    }
}
