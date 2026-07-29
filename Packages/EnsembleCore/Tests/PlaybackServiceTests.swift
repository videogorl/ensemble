import AVFoundation
@testable import EnsembleCore
import XCTest

final class PlaybackServiceTests: XCTestCase {
    func testAudioPlaybackEngineResolvedPlaybackPositionFallsBackToSeekOffsetWithoutRenderSample() {
        let time = AudioPlaybackEngine.resolvedPlaybackPosition(
            renderSampleTime: nil,
            playerTimeBaseOffset: 0,
            seekFrameOffset: 3_282_300,
            sampleRate: 44100
        )

        XCTAssertEqual(time, 74.428571, accuracy: 0.0001)
    }

    func testAudioPlaybackEngineResolvedPlaybackPositionSubtractsGaplessBaseOffset() {
        let time = AudioPlaybackEngine.resolvedPlaybackPosition(
            renderSampleTime: 350,
            playerTimeBaseOffset: 100,
            seekFrameOffset: 25,
            sampleRate: 10
        )

        XCTAssertEqual(time, 27.5, accuracy: 0.0001)
    }

    func testCurrentPlaybackPositionUsesDurablePlayheadWhenRenderClockIsUnavailable() {
        let time = AudioPlaybackEngine.resolvedCurrentPlaybackPosition(
            renderClockPosition: nil,
            durablePlaybackPosition: 132.4,
            duration: 274.2
        )

        XCTAssertEqual(time, 132.4, accuracy: 0.0001)
    }

    func testCurrentPlaybackPositionClampsDurablePlayheadToDuration() {
        let time = AudioPlaybackEngine.resolvedCurrentPlaybackPosition(
            renderClockPosition: nil,
            durablePlaybackPosition: 288.0,
            duration: 274.2
        )

        XCTAssertEqual(time, 274.2, accuracy: 0.0001)
    }

    func testInstrumentalModeUsesLargeRenderSlicesForIsolationHeadroom() {
        XCTAssertEqual(AudioPlaybackEngine.instrumentalIsolationMaxFramesToRender, 8192)
        XCTAssertGreaterThan(AudioPlaybackEngine.instrumentalIsolationPreferredIOBufferDuration, 0.12)
        XCTAssertLessThan(AudioPlaybackEngine.standardPreferredIOBufferDuration, 0.03)
    }

    func testSmartMixIncomingPositionUsesTempoRate() {
        let position = AudioPlaybackEngine.smartMixIncomingPosition(
            incomingStartTime: 10,
            elapsed: 5,
            incomingPlaybackRate: 0.98,
            duration: 180
        )

        XCTAssertEqual(position, 14.9, accuracy: 0.0001)
    }

    func testSmartMixIncomingPositionClampsToDuration() {
        let position = AudioPlaybackEngine.smartMixIncomingPosition(
            incomingStartTime: 175,
            elapsed: 10,
            incomingPlaybackRate: 1.04,
            duration: 180
        )

        XCTAssertEqual(position, 180, accuracy: 0.0001)
    }

    func testSmartMixHighPassFrequencyRampsAfterStartProgress() {
        let sweep = SmartMixHighPassSweep(startFrequency: 80, endFrequency: 700, startProgress: 0.35)

        XCTAssertEqual(
            AudioPlaybackEngine.smartMixHighPassFrequency(progress: 0.2, sweep: sweep, sampleRate: 44100),
            80,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AudioPlaybackEngine.smartMixHighPassFrequency(progress: 1, sweep: sweep, sampleRate: 44100),
            700,
            accuracy: 0.001
        )
    }

    func testSmartMixDefaultHighPassSweepIsStrongerAndEased() {
        let sweep = SmartMixHighPassSweep.subtle

        XCTAssertEqual(sweep.startFrequency, 90)
        XCTAssertEqual(sweep.endFrequency, 1_400)
        XCTAssertEqual(sweep.startProgress, 0.25)
        XCTAssertEqual(
            AudioPlaybackEngine.smartMixHighPassFrequency(progress: 0.625, sweep: sweep, sampleRate: 44100),
            745,
            accuracy: 0.001
        )
    }

    func testSmartMixTempoRateEasesTowardTarget() {
        XCTAssertEqual(
            AudioPlaybackEngine.smartMixTempoRate(progress: 0.05, targetRate: 1.08),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            AudioPlaybackEngine.smartMixTempoRate(progress: 1, targetRate: 1.08),
            1.08,
            accuracy: 0.0001
        )
    }

    func testSmartMixFormatsMatchAllowsSampleRateConversionForEquivalentDeckFormats() {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        let stereoCopy = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        let stereo48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)

        XCTAssertTrue(AudioPlaybackEngine.smartMixFormatsMatch(stereo, stereoCopy!))
        XCTAssertTrue(AudioPlaybackEngine.smartMixFormatsMatch(stereo, stereo48k!))
        XCTAssertFalse(AudioPlaybackEngine.smartMixFormatsMatch(stereo, mono!))
        XCTAssertFalse(AudioPlaybackEngine.smartMixFormatsMatch(nil, stereo!))
    }

    func testRouteRecoveryPrefersObservedPositionWhenLiveTimeDropsToZero() {
        let time = AudioPlaybackEngine.resolvedRouteRecoveryPosition(
            livePosition: 0,
            observedPosition: 87.8,
            duration: 201.4
        )

        XCTAssertEqual(time, 87.8, accuracy: 0.0001)
    }

    func testRouteRecoveryKeepsLivePositionWhenObservedPositionIsStale() {
        let time = AudioPlaybackEngine.resolvedRouteRecoveryPosition(
            livePosition: 10.0,
            observedPosition: 87.8,
            duration: 201.4
        )

        XCTAssertEqual(time, 10.0, accuracy: 0.0001)
    }

    func testRouteRecoveryPrefersPendingSnapshotOverStaleLivePosition() {
        let time = AudioPlaybackEngine.resolvedRouteRecoveryPosition(
            livePosition: 146.0,
            observedPosition: 161.0,
            duration: 294.5,
            preferredSnapshot: 161.0
        )

        XCTAssertEqual(time, 161.0, accuracy: 0.0001)
    }

    func testPreparedRouteRecoveryUsesObservedTimeWhenRenderClockIsUnavailable() {
        let time = AudioPlaybackEngine.resolvedPreparedRouteRecoveryPosition(
            renderClockPosition: nil,
            observedPosition: 116.1,
            fallbackPosition: 75.3696,
            duration: 249.9
        )

        XCTAssertEqual(time, 116.1, accuracy: 0.0001)
    }

    func testPreparedRouteRecoveryFallsBackWhenObservedTimeIsUnavailable() {
        let time = AudioPlaybackEngine.resolvedPreparedRouteRecoveryPosition(
            renderClockPosition: nil,
            observedPosition: 0.0,
            fallbackPosition: 75.3696,
            duration: 249.9
        )

        XCTAssertEqual(time, 75.3696, accuracy: 0.0001)
    }

    func testRestoredPausedSeekTimeClampsExactTrackEnd() {
        let restored = PlaybackService.restoredPausedSeekTime(
            savedTime: 270.85061224489795,
            duration: 270.85061224489795
        )

        XCTAssertEqual(restored, 270.8496122448979, accuracy: 0.0001)
    }

    func testRestoredPausedSeekTimeLeavesInteriorPositionsUntouched() {
        let restored = PlaybackService.restoredPausedSeekTime(
            savedTime: 108.09313673675985,
            duration: 289.1861224489796
        )

        XCTAssertEqual(restored, 108.09313673675985, accuracy: 0.0001)
    }

    func testAudioEnginePreparationCreatesMissingEngineAfterStop() {
        let action = PlaybackService.audioEnginePreparation(
            hasAudioEngine: false,
            playbackState: .stopped
        )

        XCTAssertEqual(action, .createMissing)
    }

    func testAudioEnginePreparationRecreatesFailedEngine() {
        let action = PlaybackService.audioEnginePreparation(
            hasAudioEngine: true,
            playbackState: .failed("Audio engine not initialized")
        )

        XCTAssertEqual(action, .recreateFailed)
    }

    func testAudioEnginePreparationReusesHealthyEngine() {
        let action = PlaybackService.audioEnginePreparation(
            hasAudioEngine: true,
            playbackState: .paused
        )

        XCTAssertEqual(action, .reuseExisting)
    }

    func testPresentationRouteKindPrefersAirPlayOverBluetooth() {
        let routeKind = PlaybackService.inferPresentationRouteKind(
            hasAirPlay: true,
            hasBluetooth: true
        )

        XCTAssertEqual(routeKind, .airPlay)
    }

    func testPresentationRouteKindDefaultsToBuiltInWithNoExternalRoutes() {
        let routeKind = PlaybackService.inferPresentationRouteKind(
            hasAirPlay: false,
            hasBluetooth: false
        )
        XCTAssertEqual(routeKind, .builtInOrWired)
    }

    func testPresentationRouteKindDetectsBluetoothAlone() {
        let routeKind = PlaybackService.inferPresentationRouteKind(
            hasAirPlay: false,
            hasBluetooth: true
        )
        XCTAssertEqual(routeKind, .bluetooth)
    }

    func testScreenMirroringSuppressesAirPlayLatencyCompensation() {
        // During screen mirroring, AVAudioSession reports .airPlay because audio
        // goes through the mirroring stream. But the mirroring protocol syncs A/V
        // together — no separate delay. Route should be builtInOrWired (zero latency).
        let routeKind = PlaybackService.inferPresentationRouteKind(
            hasAirPlay: true,
            hasBluetooth: false,
            isScreenMirroringActive: true
        )
        XCTAssertEqual(routeKind, .builtInOrWired)
    }

    func testScreenMirroringStillDetectsBluetoothWhenActive() {
        // If the user has Bluetooth headphones during screen mirroring, audio goes
        // to Bluetooth (not the TV). Bluetooth latency should still apply.
        let routeKind = PlaybackService.inferPresentationRouteKind(
            hasAirPlay: false,
            hasBluetooth: true,
            isScreenMirroringActive: true
        )
        XCTAssertEqual(routeKind, .bluetooth)
    }

    func testEstimatedPresentationLatencyUsesBluetoothFallbackWhenReportedLatencyIsTiny() {
        let latency = PlaybackService.estimatedPresentationLatency(
            routeKind: .bluetooth,
            reportedOutputLatency: 0.01,
            ioBufferDuration: 0.01
        )

        XCTAssertEqual(latency, 0.22, accuracy: 0.001)
    }

    func testResolvedPresentationTimeSubtractsLatencyOnlyWhilePlaying() {
        XCTAssertEqual(
            PlaybackService.resolvedPresentationTime(
                rawTime: 20,
                playbackState: .playing,
                effectiveLatency: 1.5
            ),
            18.5,
            accuracy: 0.001
        )

        XCTAssertEqual(
            PlaybackService.resolvedPresentationTime(
                rawTime: 20,
                playbackState: .paused,
                effectiveLatency: 1.5
            ),
            20,
            accuracy: 0.001
        )
    }

    func testTrackFormattedDuration() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "Test Song",
            duration: 185 // 3:05
        )

        XCTAssertEqual(track.formattedDuration, "3:05")
    }

    func testTrackTitleFallsBackToStreamFilenameWhenEmpty() {
        let track = Track(
            id: "1",
            key: "/library/metadata/1",
            title: "  ",
            streamKey: "/library/parts/4321/Blemish%20Bass%2003202025.mp3?download=0"
        )

        XCTAssertEqual(track.title, "Blemish Bass 03202025")
    }

    func testRepeatModeCycle() {
        var mode = RepeatMode.off

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .all)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .one)

        mode = RepeatMode(rawValue: (mode.rawValue + 1) % RepeatMode.allCases.count) ?? .off
        XCTAssertEqual(mode, .off)
    }

    func testFeedbackRatingToggleForLikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: true), 10)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: true), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: true), 10)
    }

    func testFeedbackRatingToggleForDislikeCommand() {
        XCTAssertEqual(PlaybackService.feedbackRating(from: 0, isLike: false), 2)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 2, isLike: false), 0)
        XCTAssertEqual(PlaybackService.feedbackRating(from: 10, isLike: false), 2)
    }

    func testFeedbackFlagsReflectRatingBuckets() {
        let none = PlaybackService.feedbackFlags(for: 0)
        XCTAssertFalse(none.isLiked)
        XCTAssertFalse(none.isDisliked)

        let liked = PlaybackService.feedbackFlags(for: 10)
        XCTAssertTrue(liked.isLiked)
        XCTAssertFalse(liked.isDisliked)

        let disliked = PlaybackService.feedbackFlags(for: 2)
        XCTAssertFalse(disliked.isLiked)
        XCTAssertTrue(disliked.isDisliked)
    }

    func testNetworkTransitionOnlineWifiToOnlineCellularTriggersAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .online(.cellular)
        )

        XCTAssertTrue(decision.isInterfaceSwitch)
        XCTAssertTrue(decision.shouldRefreshConnection)
        XCTAssertTrue(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOnlineWifiToOnlineWifiDoesNotAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .online(.wifi)
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertFalse(decision.shouldRefreshConnection)
        XCTAssertFalse(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOfflineToOnlineCellularTriggersReconnectAndAutoHeal() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .offline,
            to: .online(.cellular)
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertTrue(decision.shouldRefreshConnection)
        XCTAssertTrue(decision.shouldAutoHealQueue)
        XCTAssertTrue(decision.shouldHandleReconnect)
        XCTAssertFalse(decision.shouldHandleDisconnect)
    }

    func testNetworkTransitionOnlineToOfflineTriggersDisconnectHandling() {
        let decision = PlaybackService.evaluateNetworkTransition(
            from: .online(.wifi),
            to: .offline
        )

        XCTAssertFalse(decision.isInterfaceSwitch)
        XCTAssertFalse(decision.shouldRefreshConnection)
        XCTAssertFalse(decision.shouldAutoHealQueue)
        XCTAssertFalse(decision.shouldHandleReconnect)
        XCTAssertTrue(decision.shouldHandleDisconnect)
    }

    func testAutomaticAdvanceGateRejectsOldTrackTimeSample() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeAfterAutomaticAdvance(
            observedTime: 248.0,
            elapsedSinceAdvance: 0.12
        )

        XCTAssertTrue(shouldIgnore)
    }

    func testAutomaticAdvanceGateAcceptsNewTrackTimeSample() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeAfterAutomaticAdvance(
            observedTime: 0.18,
            elapsedSinceAdvance: 0.12
        )

        XCTAssertFalse(shouldIgnore)
    }

    func testAutomaticAdvanceGateExpiresQuickly() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeAfterAutomaticAdvance(
            observedTime: 248.0,
            elapsedSinceAdvance: 0.9
        )

        XCTAssertFalse(shouldIgnore)
    }

    func testPlaybackSnapshotPersistsAfterInterval() {
        XCTAssertTrue(
            PlaybackService.shouldPersistPlaybackSnapshot(
                observedTime: 30,
                lastSavedTime: 10
            )
        )
    }

    func testPlaybackSnapshotSkipsFrequentWrites() {
        XCTAssertFalse(
            PlaybackService.shouldPersistPlaybackSnapshot(
                observedTime: 20,
                lastSavedTime: 10
            )
        )
    }

    func testEngineTrackReconciliationTriggersWhenEngineAndUIDiverge() {
        XCTAssertTrue(
            PlaybackService.shouldReconcileEngineTrack(
                currentTrackID: "8877",
                engineTrackID: "8878",
                isSkipTransitionInProgress: false
            )
        )
    }

    func testEngineTrackReconciliationSkipsDuringManualTransitions() {
        XCTAssertFalse(
            PlaybackService.shouldReconcileEngineTrack(
                currentTrackID: "8877",
                engineTrackID: "8878",
                isSkipTransitionInProgress: true
            )
        )
    }

    func testEngineTrackReconciliationSkipsDuringSmartMixTransition() {
        XCTAssertFalse(
            PlaybackService.shouldReconcileEngineTrack(
                currentTrackID: "8877",
                engineTrackID: "8878",
                isSkipTransitionInProgress: false,
                isSmartMixTransitionActive: true
            )
        )
    }

    func testAutomaticAdvanceIsSuppressedDuringInterruption() {
        var coordinator = PlaybackHandoffCoordinator()
        _ = coordinator.handle(.interruptionBegan(now: Date()), playbackState: .playing)

        XCTAssertTrue(
            PlaybackService.shouldSuppressAutomaticAdvanceDuringHandoff(
                coordinator: coordinator,
                isInterrupted: true,
                isRouteChangeInProgress: false
            )
        )
    }

    func testAutomaticAdvanceIsSuppressedDuringDisconnectTransition() {
        var coordinator = PlaybackHandoffCoordinator()
        _ = coordinator.handle(
            .routeChanged(reason: .oldDeviceUnavailable, now: Date(), settleUntil: nil),
            playbackState: .playing
        )

        XCTAssertTrue(
            PlaybackService.shouldSuppressAutomaticAdvanceDuringHandoff(
                coordinator: coordinator,
                isInterrupted: false,
                isRouteChangeInProgress: true
            )
        )
    }

    func testRemoteSkipCommandsDisabledWhileBuffering() {
        let coordinator = PlaybackHandoffCoordinator()

        XCTAssertFalse(
            PlaybackService.remoteSkipCommandsEnabled(
                playbackState: .buffering,
                coordinator: coordinator,
                isInterrupted: false,
                isRouteChangeInProgress: false
            )
        )
    }

    func testRemoteSkipCommandsDisabledDuringInterruption() {
        var coordinator = PlaybackHandoffCoordinator()
        _ = coordinator.handle(.interruptionBegan(now: Date()), playbackState: .playing)

        XCTAssertFalse(
            PlaybackService.remoteSkipCommandsEnabled(
                playbackState: .paused,
                coordinator: coordinator,
                isInterrupted: true,
                isRouteChangeInProgress: false
            )
        )
    }

    func testRemoteSkipCommandsEnabledForStablePausedPlayback() {
        var coordinator = PlaybackHandoffCoordinator()
        _ = coordinator.handle(.pauseRequested(.user), playbackState: .playing)

        XCTAssertTrue(
            PlaybackService.remoteSkipCommandsEnabled(
                playbackState: .paused,
                coordinator: coordinator,
                isInterrupted: false,
                isRouteChangeInProgress: false
            )
        )
    }

    func testEffectiveDurationPrefersLongerItemDuration() {
        let effective = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: 186.10
        )

        XCTAssertEqual(effective, 186.10, accuracy: 0.001)
    }

    func testEffectiveDurationFallsBackToMetadataForInvalidItemDuration() {
        let effectiveNaN = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: .nan
        )
        let effectiveNegative = PlaybackService.effectiveDuration(
            metadataDuration: 179.44,
            itemDuration: -1
        )

        XCTAssertEqual(effectiveNaN, 179.44, accuracy: 0.001)
        XCTAssertEqual(effectiveNegative, 179.44, accuracy: 0.001)
    }

    func testEnabledSourceCompositeKeysIncludesOnlyEnabledLibraries() {
        let accounts = [
            PlexAccountConfig(
                id: "account-1",
                email: "user@example.com",
                plexUsername: "felicity",
                displayTitle: "Felicity",
                authToken: "token",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server 1",
                        url: "https://server-1.example.com",
                        connections: [],
                        token: "server-token",
                        platform: "Linux",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Library One", isEnabled: true),
                            PlexLibraryConfig(id: "lib-2", key: "lib-2", title: "Library Two", isEnabled: false),
                        ]
                    ),
                ]
            ),
        ]

        let keys = PlaybackService.enabledSourceCompositeKeys(from: accounts)

        XCTAssertEqual(keys, ["plex:account-1:server-1:lib-1"])
    }

    func testPruneQueueRemovesDisabledSourceItemsAndAdvancesToNextAvailable() {
        let current = QueueItem(
            id: "current",
            track: Track(
                id: "track-1",
                key: "/library/metadata/1",
                title: "Current",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .continuePlaying
        )
        let next = QueueItem(
            id: "next",
            track: Track(
                id: "track-2",
                key: "/library/metadata/2",
                title: "Next",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )
        let removedLater = QueueItem(
            id: "removed",
            track: Track(
                id: "track-3",
                key: "/library/metadata/3",
                title: "Removed",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .autoplay
        )

        let result = PlaybackService.pruneQueueForEnabledSources(
            queue: [current, next, removedLater],
            originalQueue: [current, next, removedLater],
            playbackHistory: [current, next],
            currentQueueIndex: 0,
            enabledSourceCompositeKeys: ["plex:account-1:server-1:lib-enabled"]
        )

        XCTAssertEqual(result.queue.map(\.id), ["next"])
        XCTAssertEqual(result.originalQueue.map(\.id), ["next"])
        XCTAssertEqual(result.playbackHistory.map(\.id), ["next"])
        XCTAssertEqual(result.nextCurrentQueueIndex, 0)
        XCTAssertTrue(result.removedCurrentQueueItem)
        XCTAssertEqual(result.removedQueueItemCount, 2)
    }

    // MARK: - effectiveDuration edge cases

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNil() {
        // When AVPlayerItem hasn't resolved its duration yet (e.g. progressive MP3 still loading),
        // we fall back to metadata duration from Plex.
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: nil)
        XCTAssertEqual(result, 180)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsInfinite() {
        // HLS/progressive streams may report .indefinite (infinity) before duration resolves.
        let result = PlaybackService.effectiveDuration(metadataDuration: 240, itemDuration: .infinity)
        XCTAssertEqual(result, 240)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNaN() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 120, itemDuration: .nan)
        XCTAssertEqual(result, 120)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsZero() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 300, itemDuration: 0)
        XCTAssertEqual(result, 300)
    }

    func testEffectiveDurationReturnsMetadataWhenItemDurationIsNegative() {
        let result = PlaybackService.effectiveDuration(metadataDuration: 200, itemDuration: -5)
        XCTAssertEqual(result, 200)
    }

    func testEffectiveDurationRejectsAbsurdlyLongItemDuration() {
        // Guard against malformed media reporting 24h+ durations
        let absurdDuration = 25 * 60 * 60.0 // 25 hours
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: absurdDuration)
        XCTAssertEqual(result, 180)
    }

    func testEffectiveDurationClampsNegativeMetadataToZero() {
        let result = PlaybackService.effectiveDuration(metadataDuration: -10, itemDuration: nil)
        XCTAssertEqual(result, 0)
    }

    func testEffectiveDurationPreferslongerDuration() {
        // Transcoded streams may produce slightly more or fewer audio frames than metadata says.
        // Prefer the longer value so the progress bar doesn't prematurely reach 100%.
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: 183)
        XCTAssertEqual(result, 183)
    }

    func testEffectiveDurationUsesMetadataWhenItemIsShorter() {
        // Metadata says 240s but AVPlayerItem resolved to 238s. Keep the longer value.
        let result = PlaybackService.effectiveDuration(metadataDuration: 240, itemDuration: 238)
        XCTAssertEqual(result, 240)
    }

    func testEffectiveDurationCapsVBROverestimate() {
        // VBR MP3 files from PMS transcode cause AVPlayer to wildly overestimate
        // duration (e.g., 195s → 270s) due to missing XING/LAME headers.
        // When AVPlayer reports >10% longer than metadata, trust metadata.
        let result = PlaybackService.effectiveDuration(metadataDuration: 195.78, itemDuration: 270.29)
        XCTAssertEqual(result, 195.78)
    }

    func testEffectiveDurationAllowsSmallItemOvershoot() {
        // AVPlayer reporting slightly longer (within 10%) is normal for transcoded
        // streams — allow it so progress bar doesn't complete early.
        let result = PlaybackService.effectiveDuration(metadataDuration: 180, itemDuration: 195)
        XCTAssertEqual(result, 195) // 8.3% over, within 10% threshold
    }

    func testNoPlayableTracksMessageDistinguishesDeviceAndServerAvailability() {
        XCTAssertEqual(
            PlaybackService.noPlayableTracksMessage(isDeviceOffline: true),
            "No downloaded tracks available offline"
        )
        XCTAssertEqual(
            PlaybackService.noPlayableTracksMessage(isDeviceOffline: false),
            "No playable tracks available — server is unreachable"
        )
    }

    // MARK: - Queue pruning

    func testPruneQueueKeepsCurrentIndexWhenCurrentSourceStillEnabled() {
        let current = QueueItem(
            id: "current",
            track: Track(
                id: "track-1",
                key: "/library/metadata/1",
                title: "Current",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )
        let removedNext = QueueItem(
            id: "removed",
            track: Track(
                id: "track-2",
                key: "/library/metadata/2",
                title: "Removed",
                sourceCompositeKey: "plex:account-1:server-1:lib-disabled"
            ),
            source: .continuePlaying
        )
        let otherEnabled = QueueItem(
            id: "other",
            track: Track(
                id: "track-3",
                key: "/library/metadata/3",
                title: "Other Enabled",
                sourceCompositeKey: "plex:account-1:server-1:lib-enabled"
            ),
            source: .continuePlaying
        )

        let result = PlaybackService.pruneQueueForEnabledSources(
            queue: [current, removedNext, otherEnabled],
            originalQueue: [current, removedNext, otherEnabled],
            playbackHistory: [],
            currentQueueIndex: 0,
            enabledSourceCompositeKeys: ["plex:account-1:server-1:lib-enabled"]
        )

        XCTAssertEqual(result.queue.map(\.id), ["current", "other"])
        XCTAssertEqual(result.nextCurrentQueueIndex, 0)
        XCTAssertFalse(result.removedCurrentQueueItem)
        XCTAssertEqual(result.removedQueueItemCount, 1)
    }

    func testAppleMusicTracksRemainPlayableWithoutAPlexServer() {
        let track = Track(
            id: "apple-track",
            key: "apple-catalog",
            title: "Apple Track",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertTrue(PlaybackService.isQueueTrackPlayable(track, serverPossiblyAvailable: false))
        XCTAssertTrue(PlaybackService.isTrackSourceAvailable(track, enabledSourceCompositeKeys: []))
    }

    func testAppleMusicSegmentStopsBeforeDuplicateQueueEntry() {
        let apple = Track(
            id: "apple-track",
            key: "apple-catalog",
            title: "Apple Track",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        XCTAssertEqual(PlaybackService.appleMusicSegment(from: [apple, apple]).count, 1)
    }

    func testAppleMusicResolutionSkipsOnlyUnresolvedLaterItems() throws {
        let first = makeAppleTrack(id: "first")
        let unresolvedMiddle = makeAppleTrack(id: "unresolved-middle")
        let resolvedLater = makeAppleTrack(id: "resolved-later")
        let unresolvedTail = makeAppleTrack(id: "unresolved-tail")

        let resolution = try XCTUnwrap(AppleMusicPlaybackResolutionPolicy.select(
            requestedTracks: [first, unresolvedMiddle, resolvedLater, unresolvedTail],
            resolvedPlaybackIdentities: [first.playbackIdentity, resolvedLater.playbackIdentity]
        ))

        XCTAssertEqual(resolution.resolvedTracks, [first, resolvedLater])
        XCTAssertEqual(
            resolution.unresolvedPlaybackIdentities,
            [unresolvedMiddle.playbackIdentity, unresolvedTail.playbackIdentity]
        )
    }

    func testAppleMusicResolutionRequiresTheSelectedFirstItem() {
        let first = makeAppleTrack(id: "first")
        let later = makeAppleTrack(id: "later")

        XCTAssertNil(AppleMusicPlaybackResolutionPolicy.select(
            requestedTracks: [first, later],
            resolvedPlaybackIdentities: [later.playbackIdentity]
        ))
        XCTAssertNil(AppleMusicPlaybackResolutionPolicy.select(
            requestedTracks: [first, later],
            resolvedPlaybackIdentities: []
        ))
    }

    func testAppleMusicUnresolvedPruningPreservesDuplicateOutsideSubmittedSegment() {
        let first = QueueItem(id: "first", track: makeAppleTrack(id: "first"))
        let unresolved = QueueItem(id: "unresolved", track: makeAppleTrack(id: "duplicate"))
        let duplicateBoundary = QueueItem(id: "duplicate-boundary", track: unresolved.track)
        let plex = QueueItem(
            id: "plex",
            track: makeTrack(id: "plex", title: "Plex", artist: "Artist", duration: 180)
        )

        let result = PlaybackService.pruningUnresolvedAppleMusicItems(
            queue: [first, unresolved, duplicateBoundary, plex],
            originalQueue: [first, duplicateBoundary, unresolved, plex],
            submittedItems: [first, unresolved],
            unresolvedPlaybackIdentities: [unresolved.track.playbackIdentity]
        )

        XCTAssertEqual(result.queue.map(\.id), ["first", "duplicate-boundary", "plex"])
        XCTAssertEqual(result.originalQueue.map(\.id), ["first", "duplicate-boundary", "plex"])
        XCTAssertEqual(result.removedItemIDs, ["unresolved"])
    }

    func testAppleMusicAutoplayReplacesAnExistingAutoplaySuffix() {
        let autoplay = QueueItem(
            id: "plex-autoplay",
            track: makeTrack(id: "plex", title: "Plex", artist: "Artist", duration: 180),
            source: .autoplay
        )
        let manual = QueueItem(
            id: "manual",
            track: makeTrack(id: "manual", title: "Manual", artist: "Artist", duration: 180),
            source: .continuePlaying
        )

        XCTAssertTrue(PlaybackService.shouldStartAppleMusicAutoplay(nextItem: autoplay, isEnabled: true))
        XCTAssertTrue(PlaybackService.shouldStartAppleMusicAutoplay(nextItem: nil, isEnabled: true))
        XCTAssertFalse(PlaybackService.shouldStartAppleMusicAutoplay(nextItem: manual, isEnabled: true))
    }

    func testAppleMusicStationAdvancesPastSeedBeforePlaying() async throws {
        let player = RecordingAppleMusicStationPlayer()

        try await AppleMusicStationStartSequence.startAfterSeed(on: player)

        XCTAssertEqual(player.operations, [.prepare, .skipToNextEntry, .play])
    }

    func testAppleMusicStationDoesNotPlayWhenAdvancingPastSeedFails() async {
        let player = RecordingAppleMusicStationPlayer(failingAt: .skipToNextEntry)

        do {
            try await AppleMusicStationStartSequence.startAfterSeed(on: player)
            XCTFail("Expected station advancement to fail")
        } catch {}

        XCTAssertEqual(player.operations, [.prepare, .skipToNextEntry])
    }

    func testAppleMusicRadioDoesNotReusePlayedDuplicate() {
        let track = Track(
            id: "apple-track",
            key: "apple-catalog",
            title: "Apple Track",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let played = QueueItem(id: "played", track: track, source: .continuePlaying)
        let current = QueueItem(id: "current", track: track, source: .continuePlaying)

        XCTAssertNil(PlaybackService.futureQueueIndex(
            matching: track.playbackIdentity,
            in: [played, current],
            after: 1
        ))
    }

    private func makeTrack(
        id: String,
        title: String,
        artist: String,
        duration: TimeInterval
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            artistName: artist,
            albumArtistName: artist,
            duration: duration,
            sourceCompositeKey: "plex:account:server:library"
        )
    }

    private func makeAppleTrack(id: String) -> Track {
        Track(
            id: id,
            key: "apple-catalog",
            title: id,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
    }

    private final class RecordingAppleMusicStationPlayer: AppleMusicStationPlaybackStarting {
        enum Operation: Equatable {
            case prepare
            case skipToNextEntry
            case play
        }

        enum Failure: Error {
            case expected
        }

        let failingOperation: Operation?
        private(set) var operations: [Operation] = []

        init(failingAt failingOperation: Operation? = nil) {
            self.failingOperation = failingOperation
        }

        func prepareToPlay() async throws {
            try record(.prepare)
        }

        func skipToNextEntry() async throws {
            try record(.skipToNextEntry)
        }

        func play() async throws {
            try record(.play)
        }

        private func record(_ operation: Operation) throws {
            operations.append(operation)
            if operation == failingOperation { throw Failure.expected }
        }
    }
}
