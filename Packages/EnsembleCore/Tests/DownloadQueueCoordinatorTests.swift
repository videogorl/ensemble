import XCTest
@testable import EnsembleCore

@MainActor
final class DownloadQueueCoordinatorTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func withValue<T>(_ body: (Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(storage)
        }
    }

    func testStartIfNeededMarksQueueIdleWhenAutomaticRunDisabled() {
        var runningStates: [Bool] = []
        var refreshCount = 0

        let coordinator = DownloadQueueCoordinator(
            dependencies: .init(
                canRunAutomatically: { false },
                setQueueRunning: { runningStates.append($0) },
                refreshQueueStatus: { refreshCount += 1 },
                fetchPendingCount: { 0 },
                currentWorkMode: { .foregroundIdle },
                queueWorkerCount: { _, _ in 1 },
                runWorker: { _ in false },
                applyNetworkPolicy: {},
                finishBackgroundTask: { _ in },
                showCompletionToast: {}
            )
        )

        coordinator.startIfNeeded()

        XCTAssertFalse(coordinator.hasActiveTask)
        XCTAssertEqual(runningStates, [false])
        XCTAssertEqual(refreshCount, 1)
    }

    func testHandleBackgroundExecutionRequestFinishesWhenNoPendingDownloads() async {
        let finished = LockedBox<[Bool]>([])

        let coordinator = DownloadQueueCoordinator(
            dependencies: .init(
                canRunAutomatically: { true },
                setQueueRunning: { _ in },
                refreshQueueStatus: {},
                fetchPendingCount: { 0 },
                currentWorkMode: { .background },
                queueWorkerCount: { _, _ in 1 },
                runWorker: { _ in false },
                applyNetworkPolicy: {},
                finishBackgroundTask: { success in
                    finished.set(finished.withValue { $0 + [success] })
                },
                showCompletionToast: {}
            )
        )

        await coordinator.handleBackgroundExecutionRequest()

        XCTAssertEqual(finished.withValue { $0 }, [true])
    }

    func testQueueLoopRestartsWhenMorePendingWorkArrivesDuringWindDown() async {
        let pendingCounts = LockedBox([2, 1, 0])
        let workerRuns = LockedBox(0)
        let runningStates = LockedBox<[Bool]>([])

        let coordinator = DownloadQueueCoordinator(
            dependencies: .init(
                canRunAutomatically: { true },
                setQueueRunning: { value in
                    runningStates.set(runningStates.withValue { $0 + [value] })
                },
                refreshQueueStatus: {},
                fetchPendingCount: {
                    pendingCounts.withValue { counts in
                        counts.first ?? 0
                    }
                },
                currentWorkMode: { .foregroundIdle },
                queueWorkerCount: { _, _ in 1 },
                runWorker: { _ in
                    let current = workerRuns.withValue { $0 }
                    workerRuns.set(current + 1)
                    let remaining = pendingCounts.withValue { Array($0.dropFirst()) }
                    pendingCounts.set(remaining)
                    return true
                },
                applyNetworkPolicy: {},
                finishBackgroundTask: { _ in },
                showCompletionToast: {}
            )
        )

        coordinator.startIfNeeded()
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        XCTAssertFalse(coordinator.hasActiveTask)
        XCTAssertEqual(workerRuns.withValue { $0 }, 2)
        XCTAssertTrue(runningStates.withValue { $0 }.contains(true))
    }

    func testCancellationWaitsForWorkerShutdownBeforeClearingTask() async {
        let workerStarted = LockedBox(false)
        let workerFinished = LockedBox(false)

        let coordinator = DownloadQueueCoordinator(
            dependencies: .init(
                canRunAutomatically: { true },
                setQueueRunning: { _ in },
                refreshQueueStatus: {},
                fetchPendingCount: { 1 },
                currentWorkMode: { .foregroundIdle },
                queueWorkerCount: { _, _ in 1 },
                runWorker: { _ in
                    workerStarted.set(true)
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                            workerFinished.set(true)
                            continuation.resume()
                        }
                    }
                    return true
                },
                applyNetworkPolicy: {},
                finishBackgroundTask: { _ in },
                showCompletionToast: {}
            )
        )

        coordinator.startIfNeeded()
        while !workerStarted.withValue({ $0 }) {
            await Task.yield()
        }

        await coordinator.cancelCurrentTask()

        XCTAssertTrue(workerFinished.withValue { $0 })
        XCTAssertFalse(coordinator.hasActiveTask)
    }
}
