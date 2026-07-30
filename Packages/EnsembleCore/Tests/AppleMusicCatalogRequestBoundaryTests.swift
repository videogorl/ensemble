import XCTest
@testable import EnsembleCore

final class AppleMusicCatalogRequestBoundaryTests: XCTestCase {
    func testRequestReturnsBeforeTimeout() async throws {
        let value = try await AppleMusicCatalogRequestBoundary.run(
            timeoutNanoseconds: 1_000_000_000
        ) {
            42
        }

        XCTAssertEqual(value, 42)
    }

    func testTimeoutDoesNotWaitForCancellationResistantRequest() async throws {
        let gate = AsyncGate()
        let lateCompletion = AsyncSignal()
        let startedAt = Date()

        do {
            _ = try await AppleMusicCatalogRequestBoundary.run(
                timeoutNanoseconds: 20_000_000
            ) {
                await gate.enterAndWait()
                await lateCompletion.signal()
                return 42
            }
            XCTFail("Expected the request to time out")
        } catch let error as AppleMusicCatalogSearchRequestError {
            XCTAssertEqual(error, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        await gate.release()
        await lateCompletion.wait()
    }

    func testCancellationDoesNotWaitForCancellationResistantRequest() async throws {
        let gate = AsyncGate()
        let request = Task {
            try await AppleMusicCatalogRequestBoundary.run(
                timeoutNanoseconds: 5_000_000_000
            ) {
                await gate.enterAndWait()
                return 42
            }
        }
        await gate.waitUntilEntered()

        let startedAt = Date()
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected the request to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        await gate.release()
    }

    func testAlreadyCancelledCallerReturnsWithoutStartingARequest() async throws {
        let startGate = AsyncGate()
        let didStartRequest = AsyncSignal()
        let request = Task {
            await startGate.enterAndWait()
            return try await AppleMusicCatalogRequestBoundary.run(
                timeoutNanoseconds: 5_000_000_000
            ) {
                await didStartRequest.signal()
                return 42
            }
        }
        await startGate.waitUntilEntered()
        request.cancel()
        await startGate.release()

        do {
            _ = try await request.value
            XCTFail("Expected the request to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let didStart = await didStartRequest.isSignaled
        XCTAssertFalse(didStart)
    }
}

private actor AsyncGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        didEnter = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignaled: Bool { signaled }

    func signal() {
        signaled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
