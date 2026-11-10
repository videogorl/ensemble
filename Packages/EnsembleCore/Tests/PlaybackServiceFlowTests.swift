import AVFoundation
@testable import EnsembleCore
import EnsemblePersistence
import Foundation
import XCTest

/// Drives a real PlaybackService offline, with in-memory stores, local audio
/// files, and a real AVAudioEngine.
@MainActor
final class PlaybackServiceFlowTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryURLs = []
        super.tearDown()
    }

    /// Next while paused after relaunch, before the deferred pre-buffer runs,
    /// must not carry the restored track's saved position to the new track.
    func testPausedNextBeforeRestoredPreBufferStartsNewTrackAtZero() async throws {
        let service = await makeService()
        let restored = try makeTrack("restored")
        let next = try makeTrack("next")
        service.queue = [QueueItem(track: restored), QueueItem(track: next)]
        service.currentQueueIndex = 0
        service.currentTrack = restored
        service.playbackState = .paused
        service.updatePlaybackTimes(rawTime: 6)
        service.isPreBufferPending = true

        service.selectQueueItemWhilePaused(at: 1, caller: "test")
        await service.preBufferRestoredTrack()

        XCTAssertEqual(service.audioEngine?.currentTrackId, next.playbackIdentity)
        XCTAssertEqual(service.audioEngine?.currentTimeSubject.value.time ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(service.currentTime, 0, accuracy: 0.01)
        service.audioEngine?.stop()
    }

    /// Removing items before the current one must keep the index on the current item.
    func testQueueRemovalsKeepTheCurrentItemCurrent() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c", "d"].map { try makeTrack($0, seconds: 1) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 2
        service.currentTrack = tracks[2]
        service.playbackState = .paused

        service.removeDeletedTracks([tracks[0].playbackIdentity])

        XCTAssertEqual(service.queue.map(\.track.id), ["b", "c", "d"])
        XCTAssertEqual(service.currentQueueIndex, 1)

        // Autoplay off removes autoplay items, but not the one playing.
        let autoplay = try ["auto1", "auto2"].map { try makeTrack($0, seconds: 1) }
        service.queue = [QueueItem(track: tracks[0])] + autoplay.map { QueueItem(track: $0, source: .autoplay) }
        service.currentQueueIndex = 2
        service.currentTrack = autoplay[1]
        service.isAutoplayEnabled = true

        service.toggleAutoplay()

        XCTAssertEqual(service.queue.map(\.track.id), ["a", "auto2"])
        XCTAssertEqual(service.currentQueueIndex, 1)
    }

    /// A stream that keeps dropping after it loaded is retried for the engine's 30 s no-audio
    /// limit, however many times it drops, then the item-failure contract: skip once while
    /// playing, halt if the skipped-to item fails too. Invalid audio data (e.g. a truncated
    /// transcode) fails the item without a retry.
    func testPostStartupStreamFailureIsRetriedForThirtySecondsThenFailsTheItem() async throws {
        let toasts = ToastCenter()
        let service = await makeService(toastCenter: toasts)
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing
        var error: Error = URLError(.networkConnectionLost)

        func recover() async {
            service.recoverCurrentStream(after: error)
            await service.stallRecoveryTask?.value
        }

        for _ in 0 ..< 5 {
            service.playbackState = .playing
            await recover()
            XCTAssertEqual(service.currentQueueIndex, 0, "drops inside the window keep retrying the same item")
        }
        service.playbackState = .playing
        recoveryClock.now = service.streamRecovery.map { $0.startedAt + AudioPlaybackEngine.maximumRebufferSeconds } ?? 0
        await recover()
        XCTAssertEqual(service.currentQueueIndex, 1, "the spent window fails the item, which is skipped")
        XCTAssertEqual(toasts.currentToast?.title, "Skipped a")
        XCTAssertNil(toasts.currentToast?.action, "a skip offers no Retry")

        // The item reached by that skip gets invalid audio data: halt on the error, with no retry.
        service.playbackState = .playing
        error = ProgressiveStreamError.invalidPayload(bytesReceived: 2_864_498)
        await recover()
        XCTAssertEqual(service.currentQueueIndex, 1)
        guard case .failed = service.playbackState else {
            return XCTFail("expected halt, got \(service.playbackState)")
        }
        XCTAssertEqual(toasts.currentToast?.action?.title, "Retry", "the halt replaces the skip toast with one that offers Retry")
        XCTAssertTrue(toasts.currentToast?.isPersistent == true)
        service.playbackState = .paused
        XCTAssertNil(toasts.currentToast, "leaving the failed state dismisses the halt toast")
        service.audioEngine?.stop()
    }

    /// A damaged original falls back once to a forced transcode, from the startup path and from a
    /// stream that failed after it loaded, and only for damage in the media itself:
    /// - the fallback plays, tells the user quietly, and happens once;
    /// - a transcode that is also invalid, or that Plex refuses (400), fails the item as without a
    ///   fallback: skipped while playing, halted if the skipped-to item fails too;
    /// - a refused original (400) and a failure that is not media damage never fall back;
    /// - found while paused, nothing plays.
    func testDamagedOriginalFallsBackOnceToATranscodeAndOtherFailuresDoNot() async throws {
        let damaged = ProgressiveStreamError.damagedOriginal(reason: "test")
        enum Forced { case plays, invalid, refused }
        let rows: [(name: String, first: Error, forced: Forced, paused: Bool, fallbacks: Int)] = [
            ("damaged original plays as a transcode", damaged, .plays, false, 1),
            ("damaged original and invalid transcode fail", damaged, .invalid, false, 1),
            ("damaged original and refused transcode fail", damaged, .refused, false, 1),
            ("refused original does not fall back", ProgressiveStreamError.httpError(statusCode: 400, bodySnippet: nil), .plays, false, 0),
            ("damage found while paused starts nothing", damaged, .plays, true, 1),
        ]
        for row in rows {
            let toasts = ToastCenter()
            let service = await makeService(toastCenter: toasts)
            let audio = try makeTrack("fb")
            let track = Track(
                id: "fb", key: "/library/metadata/fb", title: "fb", duration: 10,
                streamKey: "/library/parts/fb/file.flac", sourceCompositeKey: Self.sourceCompositeKey
            )
            let next = try makeTrack("next")
            let forcedCalls = ForcedDecisionCount()
            let playable = URL(fileURLWithPath: try XCTUnwrap(audio.localFilePath))
            service.transportCoordinator = PlaybackTransportCoordinator(
                dependencies: .init(
                    networkState: { .online(.wifi) },
                    preparedLocalPlaybackURL: { URL(fileURLWithPath: $0) },
                    isClearlyInvalidLocalPayload: { _ in false },
                    ensureServerConnection: { _ in },
                    serverFailureMessage: { _ in nil },
                    makeStreamDecision: { track, _, _, force in
                        if force { forcedCalls.increment() }
                        return force
                            ? .progressiveTranscode(TranscodeStreamDecision(
                                path: "/music/:/transcode/universal/start.mp3", queryItems: [], ratingKey: track.id,
                                estimatedContentLength: 1_024, metadataDuration: track.duration
                            ))
                            : .directStream(partKey: "/library/parts/fb/file.flac")
                    },
                    assembleStreamResolution: { _, decision in
                        switch decision {
                        case .directStream: throw row.first
                        case .progressiveTranscode:
                            switch row.forced {
                            case .plays: return .directStream(playable)
                            case .invalid: throw ProgressiveStreamError.invalidPayload(bytesReceived: 9)
                            case .refused: throw ProgressiveStreamError.httpError(statusCode: 400, bodySnippet: nil)
                            }
                        }
                    },
                    refreshConnection: {},
                    shouldRetryStreamURLRequest: { _ in false },
                    mapToPlaybackError: { .unknown($0) }
                ),
                streamingQuality: { "original" }
            )
            service.queue = [QueueItem(track: track), QueueItem(track: next)]
            service.currentQueueIndex = 0
            service.currentTrack = track

            await service.playCurrentQueueItem(shouldStartPlayback: !row.paused, caller: "test")
            for _ in 0 ..< 20 { await Task.yield() }
            await service.stallRecoveryTask?.value

            XCTAssertEqual(forcedCalls.value, row.fallbacks, "\(row.name): forced decisions")
            XCTAssertEqual(service.transportCoordinator.hasFallenBackToTranscode(trackId: track.playbackIdentity), row.fallbacks == 1, row.name)
            switch (row.forced, row.fallbacks, row.paused) {
            case (.plays, 1, false):
                await waitUntil(timeout: 3) { service.playbackState == .playing }
                XCTAssertEqual(service.currentQueueIndex, 0, "\(row.name): stays on the item")
                await waitUntil(timeout: 3) { toasts.currentToast?.title == "Playing at reduced quality" }
                XCTAssertEqual(toasts.currentToast?.title, "Playing at reduced quality", row.name)
                XCTAssertNil(toasts.currentToast?.action, "\(row.name): a notice offers no Retry")
                XCTAssertFalse(toasts.currentToast?.isPersistent ?? true, row.name)
            case (.plays, 1, true):
                XCTAssertEqual(service.currentQueueIndex, 0, row.name)
                XCTAssertNotEqual(service.playbackState, .playing, row.name)
            default:
                await waitUntil(timeout: 3) { service.currentQueueIndex == 1 }
                XCTAssertEqual(service.currentQueueIndex, 1, "\(row.name): the failed item is skipped")
                XCTAssertNotEqual(toasts.currentToast?.title, "Playing at reduced quality", row.name)
            }
            service.audioEngine?.stop()
        }
    }

    /// After it loaded, a damaged original reloads as a forced transcode, once; a network drop is not
    /// damage and keeps the recovery window; a second damage fails the item at once.
    func testDamagedOriginalAfterStartupReloadsOnceAndNetworkDropsDoNotFallBack() async throws {
        let service = await makeService()
        let tracks = try ["a", "b"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        let id = tracks[0].playbackIdentity

        service.playbackState = .playing
        service.recoverCurrentStream(after: URLError(.networkConnectionLost))
        await service.stallRecoveryTask?.value
        XCTAssertFalse(service.transportCoordinator.hasFallenBackToTranscode(trackId: id), "a drop is not damage")

        service.playbackState = .playing
        service.recoverCurrentStream(after: ProgressiveStreamError.damagedOriginal(reason: "test"))
        XCTAssertTrue(service.transportCoordinator.hasFallenBackToTranscode(trackId: id))
        XCTAssertEqual(service.playbackState, .buffering, "the reload is the fallback, not a failure")
        XCTAssertEqual(service.currentQueueIndex, 0)
        await service.stallRecoveryTask?.value

        service.playbackState = .playing
        service.recoverCurrentStream(after: ProgressiveStreamError.damagedOriginal(reason: "again"))
        await service.stallRecoveryTask?.value
        XCTAssertEqual(service.currentQueueIndex, 1, "damage after the fallback fails the item, which is skipped")
        service.audioEngine?.stop()
    }

    private final class ForcedDecisionCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    /// Reloads of a stream that was playing stay inside its recovery window and are paced. Each case
    /// ends with the item skipped or the next item recovering, never with a failure dropped:
    /// - a reload that fails at resolution (offline), or starts and drops again, comes back for another
    ///   try no sooner than a second apart, and none launches later than 3 s before the 30 s window
    ///   ends; only then is the item skipped. A failing reload returning by itself also proves the
    ///   playback slot is freed across the reload.
    /// - a pacing wait that overruns the window skips the item instead of launching a reload.
    /// - a replacement stream that fails during the old recovery's wait gets its own recovery.
    /// The worst case before the item fails is the last launch, at most 27 s into the window, plus
    /// one attempt: resolving the source (15 s request timeout) and the engine's 15 s startup timeout.
    func testReloadsStayInsideTheRecoveryWindowAndArePaced() async throws {
        enum Scenario { case reloadFails, reloadDrops, sleepOverruns, replacementFailsDuringSleep }
        let lastLaunch = AudioPlaybackEngine.maximumRebufferSeconds - PlaybackService.streamRecoveryMinRemaining
        for scenario in [Scenario.reloadFails, .reloadDrops, .sleepOverruns, .replacementFailsDuringSleep] {
            let name = "\(scenario)"
            let clock = recoveryClock
            clock.sleeps = []
            let start = clock.now
            let service = await makeService()
            let first = scenario == .reloadFails ? makeStreamingTrack("a") : try makeTrack("a", seconds: 200)
            let tracks = [first, try makeTrack("b", seconds: 200)]
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = tracks[0]
            let failure = URLError(.networkConnectionLost)
            var replacementRecovery: (pending: Bool, bound: Bool)?
            service.streamRecoverySleep = { [unowned service] seconds in
                XCTAssertEqual(service.currentQueueIndex, 0, "\(name): not skipped inside the window")
                switch scenario {
                case .sleepOverruns:
                    clock.sleep(seconds + 40)
                case .replacementFailsDuringSleep:
                    // The queue moves on (a gapless handoff) without cancelling the sleeping recovery, and the
                    // replacement stream fails before that wait ends.
                    service.currentQueueIndex = 1
                    service.currentTrack = tracks[1]
                    service.beginSession()
                    service.recoverCurrentStream(after: failure)
                    replacementRecovery = (service.stallRecoveryTask != nil, service.stallRecoveryBinding == service.currentRetryBinding)
                    clock.sleep(seconds)
                default:
                    XCTAssertLessThanOrEqual(clock.now + seconds - start, lastLaunch + 0.001, "\(name): no reload launches in the last 3 s of the window")
                    clock.sleep(seconds)
                }
            }
            if scenario == .sleepOverruns || scenario == .replacementFailsDuringSleep {
                service.streamRecovery = .init(itemID: service.queue[0].id, startedAt: clock.now, fromTime: 0, lastReloadAt: clock.now)
            }

            var starts = 0
            let maxStarts = scenario == .reloadDrops ? 60 : 1
            while service.currentQueueIndex == 0, starts < maxStarts {
                service.playbackState = .playing
                service.recoverCurrentStream(after: failure)
                starts += 1
                while let task = service.stallRecoveryTask { await task.value }
            }

            switch scenario {
            case .reloadFails, .reloadDrops, .sleepOverruns:
                XCTAssertEqual(service.currentQueueIndex, 1, "\(name): the spent window skips the item")
                if scenario != .sleepOverruns {
                    XCTAssertGreaterThanOrEqual(clock.now - start, lastLaunch - PlaybackService.streamRecoveryMinInterval, name)
                    XCTAssertTrue(clock.sleeps.allSatisfy { $0 >= PlaybackService.streamRecoveryMinInterval - 0.001 }, "\(name): reloads are at least a second apart")
                    XCTAssertLessThanOrEqual(clock.sleeps.count + 1, 28, "\(name): about one reload a second within the window")
                }
            case .replacementFailsDuringSleep:
                XCTAssertEqual(replacementRecovery?.pending, true, "\(name): the replacement's failure is not dropped")
                XCTAssertEqual(replacementRecovery?.bound, true, name)
                XCTAssertEqual(service.currentQueueIndex, 1, name)
                XCTAssertEqual(service.audioEngine?.currentTrackId, tracks[1].playbackIdentity, "\(name): the replacement was reloaded")
            }
            service.audioEngine?.stop()
        }
    }

    /// A retry scheduled for one session and queue item is dropped once the user moves on,
    /// whether to another track or to a second copy of the same track, and it keeps the
    /// play intent: Pause during the wait stays paused, and a paused load stays paused.
    func testPendingStreamRecoveryFollowsItsSessionItemAndIntent() async throws {
        let a = try makeTrack("a", seconds: 200)
        let b = try makeTrack("b", seconds: 200)
        func failMidStream(queue: [Track], state: PlaybackState = .playing) async -> PlaybackService {
            let service = await makeService()
            service.queue = queue.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = queue[0]
            service.playbackState = state
            service.playbackPreparationShouldStart = state != .loading
            service.updatePlaybackTimes(rawTime: 114)
            service.recoverCurrentStream(after: URLError(.networkConnectionLost))
            return service
        }

        for (name, other) in [("next", b), ("duplicate", a)] {
            let service = await failMidStream(queue: [a, other])
            // The user selects the other item before the retry runs.
            service.currentQueueIndex = 1
            service.beginSession()
            await service.stallRecoveryTask?.value
            XCTAssertNil(service.audioEngine?.currentTrackId, "\(name): the stale retry loads nothing")
            service.audioEngine?.stop()
        }

        let paused = await failMidStream(queue: [a])
        paused.pauseInternally(source: .user)
        await paused.stallRecoveryTask?.value
        XCTAssertEqual(paused.playbackState, .paused, "Pause during the wait is kept")
        XCTAssertTrue(paused.pausedStreamNeedsRefresh, "Play restarts the dead stream")
        paused.audioEngine?.stop()

        // A paused load (selecting an item while paused) fails mid-stream.
        let pausedLoad = await failMidStream(queue: [a], state: .loading)
        await pausedLoad.stallRecoveryTask?.value
        XCTAssertEqual(pausedLoad.playbackState, .paused, "a failed paused load is retried paused")
        XCTAssertEqual(pausedLoad.currentTime, 114, accuracy: 0.5, "the retry resumes from the playhead")
        pausedLoad.audioEngine?.stop()
    }

    /// The item reached by skipping a failure keeps that mark after it starts playing, so its
    /// own failure halts instead of skipping on through the queue (G11). Another item that
    /// starts clears it.
    func testItemReachedBySkipStillHaltsAfterItPlayedBriefly() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing

        await service.handleItemFailure("a failed", binding: service.currentRetryBinding!, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 1)
        service.handleEngineStarted(trackID: tracks[1].playbackIdentity, session: service.activeEngineSession)
        service.playbackState = .playing
        await service.handleItemFailure("b failed", binding: service.currentRetryBinding!, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 1, "no cascade to c")
        guard case .failed = service.playbackState else {
            return XCTFail("expected halt, got \(service.playbackState)")
        }

        // A different item starting clears a leftover mark.
        service.failureSkipItemID = service.queue[1].id
        service.currentQueueIndex = 2
        service.currentTrack = tracks[2]
        service.handleEngineStarted(trackID: tracks[2].playbackIdentity, session: service.activeEngineSession)
        XCTAssertNil(service.failureSkipItemID)
        service.audioEngine?.stop()
    }

    /// The halt toast shows ahead of an unrelated persistent toast, which returns after it, and
    /// its Retry acts only on the item and session that halted.
    func testHaltToastShowsFirstAndRetriesOnlyTheHaltedItem() async throws {
        let toasts = ToastCenter()
        let service = await makeService(toastCenter: toasts)
        let tracks = try ["a", "b"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .loading
        service.playbackPreparationShouldStart = false
        toasts.show(ToastPayload(style: .info, iconSystemName: "arrow.down", title: "Downloading", isPersistent: true))

        func halt() async throws -> ToastAction {
            await service.handleItemFailure("a failed", binding: service.currentRetryBinding!, cause: nil)
            XCTAssertEqual(toasts.currentToast?.title, "Playback stopped", "the halt is not queued behind another toast")
            return try XCTUnwrap(toasts.currentToast?.action)
        }

        // Retry after the user moved to another item does nothing.
        let staleRetry = try await halt()
        service.selectQueueItemWhilePaused(at: 1, caller: "test")
        XCTAssertEqual(toasts.currentToast?.title, "Downloading", "the displaced toast returns")
        staleRetry.handler()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(service.currentQueueIndex, 1)
        XCTAssertEqual(service.playbackState, .paused, "the stale Retry starts nothing")

        // Retry on the halted item retries it.
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing
        let retry = try await halt()
        retry.handler()
        await waitUntil(timeout: 3) { service.playbackState == .playing }
        service.audioEngine?.stop()
    }

    /// A returning server retries only a halt that a server outage caused; a media or delivery
    /// failure waits for the user. The automatic retry is not a new listen: if it fails, the
    /// item halts again instead of skipping on through the queue (G11).
    func testHealthCheckRetriesOnlyAHaltCausedByAnUnreachableServer() async throws {
        let causes: [(String, Error, Bool)] = [
            ("delivery", ProgressiveStreamError.invalidPayload(bytesReceived: 300), false),
            ("http", ProgressiveStreamError.httpError(statusCode: 503, bodySnippet: nil), false),
            ("server", URLError(.timedOut), true),
            ("dns", URLError(.cannotFindHost), true),
        ]
        for (cause, error, retries) in causes {
            let service = await makeService()
            service.syncCoordinator.serverHealthChecker.setServerStateForTesting(
                .connected(url: "https://example.com"), accountId: "account-1", serverId: "server-1"
            )
            // c is downloaded, so the offline test device could skip on to it.
            let tracks = ["a", "b"].map(makeStreamingTrack) + [try makeTrack("c")]
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 1
            service.currentTrack = tracks[1]
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            // b was reached by skipping a, and its retries are spent.
            service.failureSkipItemID = service.queue[1].id
            service.streamRecovery = spentRecovery(for: service.queue[1].id, service)
            service.recoverCurrentStream(after: error)
            await service.stallRecoveryTask?.value
            guard case .failed = service.playbackState else {
                XCTFail("\(cause): expected a halt, got \(service.playbackState)")
                continue
            }

            let generation = service.sessionGeneration
            await service.handleHealthCheckCompletion()
            XCTAssertEqual(service.sessionGeneration > generation, retries, "\(cause): retried on health")
            XCTAssertEqual(service.currentQueueIndex, 1, "\(cause): never skips on to c")
            guard case .failed = service.playbackState else {
                XCTFail("\(cause): expected to stay halted, got \(service.playbackState)")
                continue
            }
            service.audioEngine?.stop()
        }
    }

    /// Pause while a halted item's Retry is still waiting wins: the retry stops and nothing starts.
    func testPauseDuringAPendingHaltRetryStaysPaused() async throws {
        let service = await makeService()
        let track = makeStreamingTrack("a")
        service.queue = [QueueItem(track: track)]
        service.currentQueueIndex = 0
        service.currentTrack = track
        service.playbackState = .failed("a failed")

        let retry = Task { await service.retryHaltedItem(service.currentRetryBinding) }
        await Task.yield()
        service.pauseInternally(source: .user)
        await retry.value

        XCTAssertEqual(service.playbackState, .paused)
        XCTAssertEqual(service.playbackPreparationCount, 0, "no load is left running")
        service.audioEngine?.stop()
    }

    /// The mark on an item reached by skipping a failure lasts only while that item stays
    /// current: moving away and back, finishing it, or Stop ends it, so a later failure of the
    /// item is a new first failure and skips.
    func testFailureSkipMarkEndsWhenTheItemChangesOrFinishes() async throws {
        let routes: [(String, @MainActor (PlaybackService) -> Void)] = [
            ("away and back while paused", { service in
                service.selectQueueItemWhilePaused(at: 2, caller: "test")
                service.selectQueueItemWhilePaused(at: 1, caller: "test")
            }),
            ("Repeat One seek to end while paused", { service in
                service.repeatMode = .one
                service.finishCurrentItemWhilePaused()
            }),
            ("stop", { service in service.stop() }),
        ]
        for (route, perform) in routes {
            let service = await makeService()
            let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = tracks[0]
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("a failed", binding: service.currentRetryBinding!, cause: nil)
            XCTAssertEqual(service.failureSkipItemID, service.queue[1].id, "\(route): b is reached by a skip")
            service.pauseInternally(source: .user)

            perform(service)
            XCTAssertNil(service.failureSkipItemID, "\(route): the mark ends")

            if service.currentTrack != nil {
                service.repeatMode = .off
                service.playbackState = .playing
                service.playbackPreparationShouldStart = true
                await service.handleItemFailure("b failed", binding: service.currentRetryBinding!, cause: nil)
                XCTAssertEqual(service.currentQueueIndex, 2, "\(route): a new first failure skips")
            }
            service.audioEngine?.stop()
        }
    }

    /// A queue edit that keeps the item reached by a skip current keeps its mark, even when the
    /// edit moves that item's index: its failure still halts instead of skipping on (G11).
    func testQueueEditsKeepTheCurrentItemsFailureSkipMark() async throws {
        let edits: [(String, @MainActor (PlaybackService) -> Void)] = [
            ("remove an earlier item", { $0.removeFromQueue(at: 0) }),
            ("shuffle", { $0.toggleShuffle() }),
            ("move a later item before it", { $0.moveQueueItem(byId: $0.queue[3].id, from: 3, to: 0) }),
        ]
        for (edit, perform) in edits {
            let service = await makeService()
            let tracks = try ["a", "b", "c", "d"].map { try makeTrack($0) }
            service.queue = tracks.map { QueueItem(track: $0) }
            service.currentQueueIndex = 0
            service.currentTrack = tracks[0]
            service.isShuffleEnabled = false
            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("a failed", binding: service.currentRetryBinding!, cause: nil)
            let marked = service.queue[1].id
            XCTAssertEqual(service.failureSkipItemID, marked, "\(edit): b is reached by a skip")

            perform(service)
            XCTAssertEqual(service.currentQueueItemID, marked, "\(edit): b stays current")
            XCTAssertEqual(service.failureSkipItemID, marked, "\(edit): b keeps its mark")

            service.playbackState = .playing
            service.playbackPreparationShouldStart = true
            await service.handleItemFailure("b failed", binding: service.currentRetryBinding!, cause: nil)
            if case .failed = service.playbackState {} else {
                XCTFail("\(edit): b's failure halts, got \(service.playbackState) at \(service.currentQueueIndex)")
            }
            service.audioEngine?.stop()
        }
    }

    /// A health check retries an outage halt only once the current track's server has passed it,
    /// and only once per recovery: if that retry plays and then halts again before sustained
    /// progress, later checks leave it to the user.
    func testHealthCheckRetriesAnOutageHaltOnceItsServerIsBack() async throws {
        let service = await makeService()
        // The queue item is downloaded so the offline test device can play the retry; the current
        // track reads as streaming, so the health check treats the halt as its server's.
        let downloaded = try makeTrack("a")
        service.queue = [QueueItem(track: downloaded)]
        service.currentQueueIndex = 0
        service.currentTrack = makeStreamingTrack("a")
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true
        func failOnAnOutage() async {
            service.streamRecovery = spentRecovery(for: service.queue[0].id, service)
            service.recoverCurrentStream(after: URLError(.timedOut))
            await service.stallRecoveryTask?.value
        }
        await failOnAnOutage()
        guard case .failed = service.playbackState else {
            return XCTFail("expected an outage halt, got \(service.playbackState)")
        }
        func healthCheckRetries() async -> Bool {
            let generation = service.sessionGeneration
            await service.handleHealthCheckCompletion()
            return service.sessionGeneration > generation
        }

        let whileDown = await healthCheckRetries()
        XCTAssertFalse(whileDown, "a check that did not find the server retries nothing")

        service.syncCoordinator.serverHealthChecker.setServerStateForTesting(
            .connected(url: "https://example.com"), accountId: "account-1", serverId: "server-1"
        )
        let onceBack = await healthCheckRetries()
        XCTAssertTrue(onceBack, "the server is back")
        await waitUntil(timeout: 3) { service.playbackState == .playing }
        XCTAssertEqual(service.playbackState, .playing, "the retry started audio")

        await failOnAnOutage()
        guard case .failed = service.playbackState else {
            return XCTFail("expected the retry to halt, got \(service.playbackState)")
        }
        XCTAssertFalse(service.haltWaitsForServer, "one automatic retry per recovery, audio or not")
        service.audioEngine?.stop()
    }

    /// A failure handled after a delay applies only to the item and session it came from: if the
    /// item changed first, it is dropped; if the user paused first, playback stays paused.
    func testDeferredItemFailureYieldsToANewerItemOrAPause() async throws {
        let triggers: [(String, (PlaybackService) -> Void)] = [
            ("engine failure", { $0.handleEngineFailure(URLError(.badServerResponse), session: $0.activeEngineSession) }),
            ("spent stream retries", { service in
                service.streamRecovery = .init(
                    itemID: service.queue[0].id,
                    startedAt: service.streamRecoveryClock() - AudioPlaybackEngine.maximumRebufferSeconds, fromTime: 0
                )
                service.recoverCurrentStream(after: URLError(.timedOut))
            }),
        ]
        let interruptions: [(String, (PlaybackService) -> Void)] = [
            ("item changed", { service in
                service.currentQueueIndex = 1
                service.currentTrack = service.queue[1].track
            }),
            ("paused", { $0.pauseInternally(source: .user) }),
        ]
        for (trigger, fail) in triggers {
            for (interruption, interrupt) in interruptions {
                let row = "\(trigger), \(interruption)"
                let service = await makeService()
                let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
                service.queue = tracks.map { QueueItem(track: $0) }
                service.currentQueueIndex = 0
                service.currentTrack = tracks[0]
                service.playbackState = .playing
                service.playbackPreparationShouldStart = true
                let expectedIndex = interruption == "paused" ? 0 : 1

                fail(service)
                interrupt(service)
                await service.stallRecoveryTask?.value
                for _ in 0..<20 { await Task.yield() }

                XCTAssertEqual(service.currentQueueIndex, expectedIndex, "\(row): no skip")
                XCTAssertNil(service.failureSkipItemID, "\(row): no skip mark")
                if interruption == "paused" {
                    XCTAssertEqual(service.playbackState, .paused, "\(row): stays paused")
                } else if case .failed = service.playbackState {
                    XCTFail("\(row): the newer item must not halt on the older failure")
                }
                service.audioEngine?.stop()
            }
        }
    }

    /// The failure-skip mark ends when another item becomes current, even if that item's load is
    /// cancelled before it runs: returning to the marked item is a new listen.
    func testCancelledNavigationAwayStillEndsTheFailureSkipMark() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 1
        service.currentTrack = tracks[1]
        service.failureSkipItemID = service.queue[1].id
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true

        service.navigateToPreviousQueueItemWhilePlaying(at: 0)
        service.pauseInternally(source: .user)
        XCTAssertNil(service.failureSkipItemID, "a became current")

        service.navigateToNextQueueItemWhilePaused()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.currentQueueIndex, 1)
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true
        await service.handleItemFailure("b failed", binding: service.currentRetryBinding!, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 2, "b's first failure in the new listen skips")
        service.audioEngine?.stop()
    }

    /// A failure skip stops being pending once it has decided, so the item it skipped to can fail
    /// (and halt, being reached by a skip) while the skip still waits on autoplay work.
    func testSkippedToItemFailsWhileTheSkipStillRefreshesAutoplay() async throws {
        let service = await makeService()
        let radio = HeldRadioProvider()
        service.syncCoordinator.setSyncProvidersForTesting([radio.sourceIdentifier.compositeKey: radio])
        service.isAutoplayEnabled = true
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 0
        service.currentTrack = tracks[0]
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true

        service.handleEngineFailure(URLError(.badServerResponse), session: service.activeEngineSession)
        await waitUntil(timeout: 3) { radio.wasAsked }
        XCTAssertEqual(service.currentQueueIndex, 1, "the skip reached b and now waits on autoplay")

        service.handleEngineFailure(URLError(.badServerResponse), session: service.activeEngineSession)
        await waitUntil(timeout: 2) {
            if case .failed = service.playbackState { return true }
            return false
        }
        XCTAssertEqual(service.currentQueueIndex, 1, "b halts instead of skipping on")
        radio.release()
        await service.stallRecoveryTask?.value
        service.audioEngine?.stop()
    }

    /// Selecting another queue item ends the failure-skip mark even when Pause cancels that
    /// item's load during its download lookup, before its track is shown.
    func testSelectionCancelledDuringItsLookupStillEndsTheFailureSkipMark() async throws {
        let service = await makeService()
        let tracks = try ["a", "b", "c"].map { try makeTrack($0) }
        service.queue = tracks.map { QueueItem(track: $0) }
        service.currentQueueIndex = 1
        service.currentTrack = tracks[1]
        service.failureSkipItemID = service.queue[1].id
        service.playbackState = .loading
        service.playbackPreparationShouldStart = true

        let selection = Task { await service.playQueueIndex(0) }
        while service.currentQueueIndex != 0 { await Task.yield() }
        service.pauseInternally(source: .user)
        await selection.value
        XCTAssertEqual(service.currentTrack?.id, "b", "a's load was cancelled before its track showed")
        XCTAssertNil(service.failureSkipItemID, "a became current")

        service.navigateToNextQueueItemWhilePaused()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(service.currentQueueIndex, 1)
        service.playbackState = .playing
        service.playbackPreparationShouldStart = true
        await service.handleItemFailure("b failed", binding: service.currentRetryBinding!, cause: nil)
        XCTAssertEqual(service.currentQueueIndex, 2, "b's first failure in the new listen skips")
        service.audioEngine?.stop()
    }

    // MARK: - Harness

    private static let sourceCompositeKey = "plex:account-1:server-1:1"

    /// A fake uptime for the recovery pacing: sleeping advances it, so nothing waits for real.
    private final class RecoveryClock {
        var now: TimeInterval = 1_000
        var sleeps: [TimeInterval] = []
        func sleep(_ seconds: TimeInterval) { sleeps.append(seconds); now += seconds }
    }
    private let recoveryClock = RecoveryClock()

    private func spentRecovery(for itemID: String, _ service: PlaybackService) -> PlaybackService.StreamRecovery {
        .init(itemID: itemID, startedAt: service.streamRecoveryClock() - AudioPlaybackEngine.maximumRebufferSeconds, fromTime: 0)
    }

    private func makeService(toastCenter: ToastCenter? = nil) async -> PlaybackService {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server",
                        url: "https://example.com",
                        token: "token",
                        libraries: [PlexLibraryConfig(id: "library-1", key: "1", title: "Music", isEnabled: true)]
                    ),
                ]
            )
        )
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.playback-flow.network-monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.offline, debounced: false)
        let stack = CoreDataStack.inMemory()
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            artworkDownloadManager: EmptyArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        syncCoordinator.refreshProviders()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-flow-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryURLs.append(directory)
        let defaultsName = "playback-flow-\(UUID().uuidString)"
        let queueStore = PlaybackQueueStore(
            defaults: UserDefaults(suiteName: defaultsName) ?? .standard,
            snapshotURL: directory.appendingPathComponent("queue.json"),
            progressURL: directory.appendingPathComponent("progress.json")
        )
        let service = PlaybackService(
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            artworkLoader: ArtworkLoader(syncCoordinator: syncCoordinator, artworkDownloadManager: EmptyArtworkDownloadManager()),
            audioAnalyzer: FrequencyAnalysisService(),
            downloadManager: DownloadManager(coreDataStack: stack),
            queueStore: queueStore,
            trackRatingLocalStore: TrackRatingLocalStore(coreDataStack: stack),
            toastCenter: toastCenter
        )
        let clock = recoveryClock
        service.streamRecoveryClock = { clock.now }
        service.streamRecoverySleep = { clock.sleep($0) }
        return service
    }

    /// A track that only streams; the test service is offline, so loading it fails.
    private func makeStreamingTrack(_ id: String) -> Track {
        Track(
            id: id, key: "/library/metadata/\(id)", title: id, duration: 200,
            streamKey: "/library/parts/\(id)/file.mp3", sourceCompositeKey: Self.sourceCompositeKey
        )
    }

    /// A downloaded track backed by a silent local WAV file.
    private func makeTrack(_ id: String, seconds: Double = 10) throws -> Track {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-flow-\(id)-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
        temporaryURLs.append(url)
        return Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: id,
            duration: seconds,
            localFilePath: url.path,
            sourceCompositeKey: Self.sourceCompositeKey
        )
    }
}

/// An autoplay source whose recommendation request waits until released.
private final class HeldRadioProvider: MusicSourceLibrarySyncing, MusicSourceRadioProviding, @unchecked Sendable {
    let sourceIdentifier = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")
    private let lock = NSLock()
    private var asked = false
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var wasAsked: Bool { lock.withLock { asked } }

    func getRecommendedTracks(basedOn track: Track, limit: Int) async -> [Track]? {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                asked = true
                if !isReleased { waiting.append(continuation) }
                return isReleased
            }
            if resumeNow { continuation.resume() }
        }
        return []
    }

    func release() {
        let continuations = lock.withLock {
            isReleased = true
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }

    func syncLibrary(to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
    func syncLibraryIncremental(since timestamp: TimeInterval, to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { LibrarySyncResult() }
    func syncPlaylists(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { PlaylistSyncResult() }
    func syncPlaylistsIncremental(to repository: PlaylistRepositoryProtocol, forceOrphanCheck: Bool, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { PlaylistSyncResult() }
    func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
}
