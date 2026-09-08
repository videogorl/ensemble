import Foundation
import Network
import XCTest
@testable import EnsembleAPI

final class BackgroundDownloadTests: XCTestCase {
    func testNativeResumeAndDurableReceipt() async throws {
        let server = try FileServer()
        let port = expectation(description: "listener ready")
        server.listener.stateUpdateHandler = { if case .ready = $0 { port.fulfill() } }
        server.listener.start(queue: server.queue)
        await fulfillment(of: [port], timeout: 5)
        defer { server.listener.cancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.listener.port!.rawValue)/audio")!)
        for mode in ["resume", "handoff", "changed", "ignore", "malformed", "corrupt", "policy", "no-validator", "unsatisfiable", "remove"] {
            server.mode = mode
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            var transport = BackgroundDownload(directory: directory, configuration: .ephemeral)
            let received = expectation(description: mode + " partial received")
            received.assertForOverFulfill = false
            let attempt = Task {
                try await transport.file(for: request, identity: mode) { bytes, _ in
                    if bytes >= 65_536 { received.fulfill() }
                }
            }
            await fulfillment(of: [received], timeout: 5)
            if mode == "remove" { await transport.discard(identity: mode) }
            else if mode == "handoff" { await transport.handoffToBackground() }
            else { attempt.cancel() }
            do { _ = try await attempt.value; XCTFail("Expected cancellation") } catch {}
            if mode == "remove" {
                let remaining = await transport.identities()
                XCTAssertTrue(remaining.isEmpty)
                continue
            }
            if mode == "corrupt" {
                let record = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: Any]
                json["resumeData"] = Data("invalid".utf8).base64EncodedString()
                try JSONSerialization.data(withJSONObject: json).write(to: record, options: .atomic)
            }
            if mode != "handoff" { transport = BackgroundDownload(directory: directory, configuration: .ephemeral) }
            var refreshed = request
            DownloadNetworkPolicy(allowsCellularAccess: mode != "policy", allowsConstrainedNetworkAccess: mode != "policy").apply(to: &refreshed)
            let (file, response) = try await transport.file(for: refreshed, identity: mode)
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertEqual(try Data(contentsOf: file), mode == "changed" ? Data(repeating: 99, count: FileServer.data.count) : FileServer.data)
            XCTAssertEqual(response.statusCode, (mode == "resume" || mode == "handoff") ? 206 : 200)
            // Simulate death after the synchronous delegate receipt, before the actor updates its record.
            if mode == "resume" {
                let recordURL = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
                let key = recordURL.deletingPathExtension().lastPathComponent
                var record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
                record.removeValue(forKey: "status")
                record["taskID"] = 123
                try JSONSerialization.data(withJSONObject: record).write(to: recordURL, options: .atomic)
                try FileManager.default.moveItem(at: directory.appendingPathComponent(key + ".media"),
                                                 to: directory.appendingPathComponent(key + "-123.incoming"))
                let receipt: [String: Any] = ["key": key, "taskID": 123, "url": request.url!.absoluteString,
                    "status": 200, "headers": ["Content-Length": String(FileServer.data.count)], "offset": 0, "total": FileServer.data.count]
                try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent(key + "-123.receipt"), options: .atomic)
            }
            // Completed bytes survive until the queue commits the installed file.
            let restored = BackgroundDownload(directory: directory, configuration: .ephemeral)
            let completed = await restored.completedIdentities()
            XCTAssertEqual(completed, [mode])
            let (retained, _) = try await restored.existingFile(identity: mode, policy: DownloadNetworkPolicy())!
            XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: file))
            try FileManager.default.removeItem(at: retained)
            await restored.discard(identity: mode)
            let acknowledged = await restored.completedIdentities()
            XCTAssertTrue(acknowledged.isEmpty)

        }
    }
}

/// Real HTTP is necessary: URLProtocol does not exercise CFNetwork's resume archive or range behavior.
private final class FileServer: @unchecked Sendable {
    static let data = Data(repeating: 42, count: 2_097_152)
    let listener: NWListener
    let queue = DispatchQueue(label: "BackgroundDownloadTests.HTTP")
    private let lock = NSLock()
    private var currentMode = "resume"
    var mode: String {
        get { lock.lock(); defer { lock.unlock() }; return currentMode }
        set { lock.lock(); currentMode = newValue; lock.unlock() }
    }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, buffered: Data())
        }
    }
    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = buffered + data
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !done { self.read(connection, buffered: request) }
                return
            }
            let offset = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
                .flatMap { Int($0.components(separatedBy: "=").last!.components(separatedBy: "-")[0]) } ?? 0
            let mode = self.mode
            if mode == "unsatisfiable", offset > 0 {
                connection.send(content: Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let resumed = offset > 0 && mode != "changed" && mode != "ignore"
            let start = resumed ? offset + (mode == "malformed" ? 128 : 0) : 0
            let body = mode == "changed" && offset > 0 ? Data(repeating: 99, count: Self.data.count) : Self.data
            var headers = "HTTP/1.1 \(resumed ? "206 Partial Content" : "200 OK")\r\nContent-Length: \(body.count - start)\r\nETag: \(mode == "changed" && offset > 0 ? "\"changed\"" : "\"original\"")\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if mode == "no-validator" { headers = headers.replacingOccurrences(of: "ETag: \"original\"\r\n", with: "") }
            if resumed { headers += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" }
            connection.send(content: Data((headers + "\r\n").utf8), completion: .contentProcessed { _ in
                self.send(connection, body: body, offset: start)
            })
        }
    }
    private func send(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else { connection.cancel(); return }
        let end = min(offset + 65_536, body.count)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.01) { self.send(connection, body: body, offset: end) }
        })
    }
}
