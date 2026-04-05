import XCTest
@testable import EnsembleCore

@MainActor
final class PlaybackLaunchCoordinatorTests: XCTestCase {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            self.storage = value
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

    func testVisualizerPlanUsesBackgroundWhenInstrumentalModeActive() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: true,
            processorCount: 8
        )

        XCTAssertEqual(plan, .init(priority: .background, throttled: true))
    }

    func testVisualizerPlanUsesUtilityOnLowCoreDevices() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: false,
            processorCount: 2
        )

        XCTAssertEqual(plan, .init(priority: .utility, throttled: true))
    }

    func testCompleteLaunchLoadsTrackSeeksAndPrefetches() async {
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200)
        let url = URL(fileURLWithPath: "/tmp/test.mp3")

        let loadedTrackID = LockedBox<String?>(nil)
        let loadedURL = LockedBox<URL?>(nil)
        let soughtTime = LockedBox<TimeInterval?>(nil)
        let prefetchCount = LockedBox(0)
        let visualizerTrackID = LockedBox<String?>(nil)

        let coordinator = PlaybackLaunchCoordinator(
            dependencies: .init(
                processorCount: { 8 },
                isVisualizerEnabled: { true },
                isInstrumentalModeActive: { false },
                enqueueVisualizerLoad: { track, _, _ in
                    visualizerTrackID.set(track.id)
                },
                loadAndPlay: { resolvedURL, track in
                    loadedURL.set(resolvedURL)
                    loadedTrackID.set(track.id)
                },
                seek: { time in
                    soughtTime.set(time)
                },
                prefetchNext: {
                    prefetchCount.set(prefetchCount.withValue { $0 + 1 })
                }
            )
        )

        await coordinator.completeLaunch(for: track, fileURL: url, recoverySeekTime: 42)
        await Task.yield()

        XCTAssertEqual(visualizerTrackID.withValue { $0 }, "1")
        XCTAssertEqual(loadedTrackID.withValue { $0 }, "1")
        XCTAssertEqual(loadedURL.withValue { $0 }, url)
        XCTAssertEqual(soughtTime.withValue { $0 } ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(prefetchCount.withValue { $0 }, 1)
    }
}
