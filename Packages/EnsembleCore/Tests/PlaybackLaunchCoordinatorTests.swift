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

    func testVisualizerPlanUsesUtilityForScheduledPrefetch() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: false,
            processorCount: 8,
            context: .scheduledPrefetch
        )

        XCTAssertEqual(plan, .init(priority: .utility, throttled: false))
    }

    func testVisualizerPlanDelaysThrottledScheduledPrefetch() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: false,
            processorCount: 2,
            context: .scheduledPrefetch
        )

        XCTAssertEqual(
            plan,
            .init(priority: .background, throttled: true, startDelayNanoseconds: 10_000_000_000)
        )
    }

    func testVisualizerPlanUsesBackgroundForRestoredPrebufferOnLowCoreDevices() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: false,
            processorCount: 2,
            context: .restoredPrebuffer
        )

        XCTAssertEqual(plan, .init(priority: .background, throttled: true))
    }

    func testVisualizerPlanKeepsToggleImmediateOnLowCoreDevices() {
        let plan = PlaybackLaunchCoordinator.visualizerPlan(
            isVisualizerEnabled: true,
            isInstrumentalModeActive: false,
            processorCount: 2,
            context: .userVisibleToggle
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
        let loadedGeneration = LockedBox<UInt64?>(nil)

        let coordinator = PlaybackLaunchCoordinator(
            dependencies: .init(
                processorCount: { 8 },
                isVisualizerEnabled: { true },
                isInstrumentalModeActive: { false },
                enqueueVisualizerLoad: { track, _, _ in
                    visualizerTrackID.set(track.id)
                },
                loadAndPlay: { source, track, generation in
                    loadedURL.set(source.fileURL)
                    loadedTrackID.set(track.id)
                    loadedGeneration.set(generation)
                    return true
                },
                seek: { time, _ in
                    soughtTime.set(time)
                    return true
                },
                prefetchNext: {
                    prefetchCount.set(prefetchCount.withValue { $0 + 1 })
                }
            )
        )

        await coordinator.completeLaunch(
            for: track,
            source: .localFile(url),
            recoverySeekTime: 42,
            generation: 7
        )
        await Task.yield()

        XCTAssertEqual(visualizerTrackID.withValue { $0 }, "1")
        XCTAssertEqual(loadedTrackID.withValue { $0 }, "1")
        XCTAssertEqual(loadedURL.withValue { $0 }, url)
        XCTAssertEqual(loadedGeneration.withValue { $0 }, 7)
        XCTAssertEqual(soughtTime.withValue { $0 } ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(prefetchCount.withValue { $0 }, 1)
    }

    func testCompleteLaunchDoesNotPostSeekStreamingSources() async {
        let track = Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200)
        let loadedTrackID = LockedBox<String?>(nil)
        let soughtTime = LockedBox<TimeInterval?>(nil)
        let prefetchCount = LockedBox(0)
        let source = PlaybackSource.transcodedHTTP(
            URLRequest(url: URL(string: "https://example.test/start.mp3")!),
            metadata: PlaybackSourceMetadata(
                trackId: track.playbackIdentity,
                ratingKey: track.id,
                estimatedContentLength: nil,
                duration: track.duration,
                startTime: 42,
                isSeekable: false,
                cacheFileExtension: "mp3"
            )
        )

        let coordinator = PlaybackLaunchCoordinator(
            dependencies: .init(
                processorCount: { 8 },
                isVisualizerEnabled: { true },
                isInstrumentalModeActive: { false },
                enqueueVisualizerLoad: { _, _, _ in },
                loadAndPlay: { _, track, _ in
                    loadedTrackID.set(track.id)
                    return true
                },
                seek: { time, _ in
                    soughtTime.set(time)
                    return true
                },
                prefetchNext: {
                    prefetchCount.set(prefetchCount.withValue { $0 + 1 })
                }
            )
        )

        await coordinator.completeLaunch(
            for: track,
            source: source,
            recoverySeekTime: 42,
            generation: 7
        )
        await Task.yield()

        XCTAssertEqual(loadedTrackID.withValue { $0 }, "1")
        XCTAssertNil(soughtTime.withValue { $0 })
        XCTAssertEqual(prefetchCount.withValue { $0 }, 1)
    }

    func testSupersededLaunchDoesNotSeekOrPrefetch() async {
        let soughtTime = LockedBox<TimeInterval?>(nil)
        let prefetchCount = LockedBox(0)
        let coordinator = PlaybackLaunchCoordinator(
            dependencies: .init(
                processorCount: { 8 },
                isVisualizerEnabled: { false },
                isInstrumentalModeActive: { false },
                enqueueVisualizerLoad: { _, _, _ in },
                loadAndPlay: { _, _, _ in false },
                seek: { time, _ in
                    soughtTime.set(time)
                    return true
                },
                prefetchNext: {
                    prefetchCount.set(prefetchCount.withValue { $0 + 1 })
                }
            )
        )

        await coordinator.completeLaunch(
            for: Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200),
            source: .localFile(URL(fileURLWithPath: "/tmp/test.mp3")),
            recoverySeekTime: 42,
            generation: 7
        )
        await Task.yield()

        XCTAssertNil(soughtTime.withValue { $0 })
        XCTAssertEqual(prefetchCount.withValue { $0 }, 0)
    }

    func testSupersededRecoverySeekDoesNotPrefetch() async {
        let seekGeneration = LockedBox<UInt64?>(nil)
        let prefetchCount = LockedBox(0)
        let coordinator = PlaybackLaunchCoordinator(
            dependencies: .init(
                processorCount: { 8 },
                isVisualizerEnabled: { false },
                isInstrumentalModeActive: { false },
                enqueueVisualizerLoad: { _, _, _ in },
                loadAndPlay: { _, _, _ in true },
                seek: { _, generation in
                    seekGeneration.set(generation)
                    return false
                },
                prefetchNext: {
                    prefetchCount.set(prefetchCount.withValue { $0 + 1 })
                }
            )
        )

        await coordinator.completeLaunch(
            for: Track(id: "1", key: "/library/metadata/1", title: "Test", duration: 200),
            source: .localFile(URL(fileURLWithPath: "/tmp/test.mp3")),
            recoverySeekTime: 42,
            generation: 7
        )
        await Task.yield()

        XCTAssertEqual(seekGeneration.withValue { $0 }, 7)
        XCTAssertEqual(prefetchCount.withValue { $0 }, 0)
    }
}
