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

    func testSmartMixPrimaryHandoffPreparationStartsNearTransitionEnd() {
        XCTAssertFalse(AudioPlaybackEngine.shouldPrepareSmartMixPrimaryHandoff(
            elapsed: 9.70,
            transitionDuration: 10,
            handoffDuration: 0.25
        ))
        XCTAssertTrue(AudioPlaybackEngine.shouldPrepareSmartMixPrimaryHandoff(
            elapsed: 9.75,
            transitionDuration: 10,
            handoffDuration: 0.25
        ))
    }

    func testSmartMixPrimaryHandoffQueuesTransitionEndPosition() {
        let position = AudioPlaybackEngine.smartMixPrimaryHandoffStartPosition(
            targetPosition: nil,
            incomingStartTime: 10,
            transitionDuration: 10,
            incomingPlaybackRate: 1,
            duration: 180
        )

        XCTAssertEqual(position, 20, accuracy: 0.0001)
    }

    func testSmartMixPrimaryHandoffClampsExplicitTargetPosition() {
        let position = AudioPlaybackEngine.smartMixPrimaryHandoffStartPosition(
            targetPosition: 200,
            incomingStartTime: 10,
            transitionDuration: 10,
            incomingPlaybackRate: 1,
            duration: 180
        )

        XCTAssertEqual(position, 179.95, accuracy: 0.0001)
    }

    func testSmartMixDeckFrameCountSchedulesOnlyHandoffTail() {
        let frames = AudioPlaybackEngine.smartMixDeckFrameCount(
            incomingStartFrame: 441_000,
            contentEndFrame: 44_100_000,
            sampleRate: 44_100,
            transitionDuration: 10,
            incomingPlaybackRate: 1,
            stabilizationDuration: 0.25,
            tailDuration: 2
        )

        XCTAssertEqual(frames, 540_225)
    }

    func testSmartMixDeckFrameCountClampsToContentEnd() {
        let frames = AudioPlaybackEngine.smartMixDeckFrameCount(
            incomingStartFrame: 990,
            contentEndFrame: 1_000,
            sampleRate: 100,
            transitionDuration: 10,
            incomingPlaybackRate: 1,
            stabilizationDuration: 0.25,
            tailDuration: 2
        )

        XCTAssertEqual(frames, 10)
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

    func testObservedTimeSyncAcceptsSamplesNearPendingSeekTarget() {
        let isSynchronized = PlaybackService.isObservedTimeSynchronizedWithPendingSeek(
            observedTime: 120.8,
            pendingSeekTargetTime: 120.0
        )

        XCTAssertTrue(isSynchronized)
    }

    func testObservedTimeSyncRejectsDistantSamplesDuringPendingSeek() {
        let isSynchronized = PlaybackService.isObservedTimeSynchronizedWithPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0
        )

        XCTAssertFalse(isSynchronized)
    }

    func testPendingSeekGateIgnoresUnsyncedSamplesDuringInitialWindow() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeDuringPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 0.3
        )

        XCTAssertTrue(shouldIgnore)
    }

    func testPendingSeekGateStopsIgnoringAfterTimeout() {
        let shouldIgnore = PlaybackService.shouldIgnoreObservedTimeDuringPendingSeek(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 1.2
        )

        XCTAssertFalse(shouldIgnore)
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
                playbackState: .paused,
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
                playbackState: .paused,
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

    func testBaseBufferingProfileForWifiUsesLowLatencyAndDepthOne() {
        let profile = PlaybackService.baseBufferingProfile(for: .online(.wifi))
        XCTAssertFalse(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 8)
        XCTAssertEqual(profile.prefetchDepth, 1)
        XCTAssertEqual(profile.stallRecoveryTimeout, 8)
    }

    func testBaseBufferingProfileForCellularUsesConservativeBuffering() {
        let profile = PlaybackService.baseBufferingProfile(for: .online(.cellular))
        XCTAssertTrue(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.preferredForwardBufferDuration, 18)
        XCTAssertEqual(profile.prefetchDepth, 1)
        XCTAssertEqual(profile.stallRecoveryTimeout, 12)
    }

    func testBaseBufferingProfileForOfflineUsesSinglePrefetchDepth() {
        let profile = PlaybackService.baseBufferingProfile(for: .offline)
        XCTAssertTrue(profile.waitsToMinimizeStalling)
        XCTAssertEqual(profile.prefetchDepth, 1)
    }

    func testResolvedBufferingProfileUsesConservativeProfileDuringEscalationWindow() {
        let now = Date()
        let conservativeUntil = now.addingTimeInterval(60)
        let profile = PlaybackService.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: conservativeUntil,
            now: now
        )
        XCTAssertEqual(profile, .conservative)
        // Conservative keeps prefetchDepth=1 to preserve gapless transitions
        XCTAssertEqual(profile.prefetchDepth, 1)
    }

    func testResolvedBufferingProfileFallsBackToBaseProfileAfterEscalationExpires() {
        let now = Date()
        let conservativeUntil = now.addingTimeInterval(-1)
        let profile = PlaybackService.resolvedBufferingProfile(
            for: .online(.wifi),
            conservativeModeUntil: conservativeUntil,
            now: now
        )
        XCTAssertEqual(profile, .wifiOrWired)
    }

    func testWaitingStallEventRequiresPlayingAndBufferEmpty() {
        XCTAssertTrue(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .loading,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: false,
                hasActiveSeek: false
            )
        )

        XCTAssertFalse(
            PlaybackService.shouldRecordWaitingStallEvent(
                playbackState: .playing,
                isPlaybackBufferEmpty: true,
                hasActiveSeek: true
            )
        )
    }

    func testUnexpectedPauseRecoveryActionReturnsImmediateResumeWhenBufferHealthy() {
        let action = PlaybackService.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: true,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: false,
            hasActiveSeek: false
        )

        XCTAssertEqual(action?.resumeImmediately, true)
        XCTAssertEqual(action?.recordStallEvent, false)
    }

    func testUnexpectedPauseRecoveryActionSchedulesRecoveryWhenBufferNotReady() {
        let action = PlaybackService.unexpectedPauseRecoveryAction(
            playbackState: .playing,
            isPlaybackLikelyToKeepUp: false,
            isPlaybackBufferFull: false,
            isPlaybackBufferEmpty: true,
            hasActiveSeek: false
        )

        XCTAssertEqual(action?.resumeImmediately, false)
        XCTAssertEqual(action?.recordStallEvent, true)
    }

    func testTransportRecoveryIncludesNetworkConnectionLost() {
        XCTAssertTrue(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorNetworkConnectionLost,
                domain: NSURLErrorDomain
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorCancelled,
                domain: NSURLErrorDomain
            )
        )
        XCTAssertFalse(
            PlaybackService.shouldForceTransportRecovery(
                errorCode: NSURLErrorNetworkConnectionLost,
                domain: NSCocoaErrorDomain
            )
        )
    }

    func testPrefetchThrottlePreservesMinimumDepthForGapless() {
        // wifiOrWired has prefetchDepth=1 — throttle is a no-op (preserves gapless)
        let wifiProfile = PlaybackService.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: true)
        XCTAssertEqual(wifiProfile.prefetchDepth, 1)
        XCTAssertEqual(wifiProfile, .wifiOrWired)

        // Profiles with depth > 1 get reduced to 1, not 0
        let deepProfile = PlaybackService.PlaybackBufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 8,
            prefetchDepth: 3,
            stallRecoveryTimeout: 8,
            label: "deep"
        )
        let throttled = PlaybackService.throttledPrefetchProfileIfNeeded(deepProfile, throttleActive: true)
        XCTAssertEqual(throttled.prefetchDepth, 1)
        XCTAssertTrue(throttled.label.contains("prefetch-throttled"))
    }

    func testPrefetchThrottleLeavesProfileUntouchedWhenInactive() {
        let profile = PlaybackService.throttledPrefetchProfileIfNeeded(.wifiOrWired, throttleActive: false)
        XCTAssertEqual(profile, .wifiOrWired)
    }

    func testConservativeEscalationTriggersAfterTwoStallsWithinWindow() {
        let now = Date()
        let stalls = [
            now.addingTimeInterval(-10),
            now.addingTimeInterval(-5),
        ]

        XCTAssertTrue(
            PlaybackService.shouldEnterConservativeMode(
                stallTimestamps: stalls,
                now: now
            )
        )
    }

    func testConservativeEscalationDoesNotTriggerWhenStallsAreOutsideWindow() {
        let now = Date()
        let stalls = [
            now.addingTimeInterval(-40),
            now.addingTimeInterval(-35),
        ]

        XCTAssertFalse(
            PlaybackService.shouldEnterConservativeMode(
                stallTimestamps: stalls,
                now: now
            )
        )
    }

    func testPendingSeekGateStaysActiveWhileBufferingAndUnsynchronized() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .buffering
        )

        XCTAssertTrue(shouldGate)
    }

    func testPendingSeekGateReleasesWhenUnsynchronizedAndNotBuffering() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 44.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .playing
        )

        XCTAssertFalse(shouldGate)
    }

    func testPendingSeekGateReleasesWhenBufferingButObservedTimeIsAhead() {
        let shouldGate = PlaybackService.shouldContinueSeekProgressGate(
            observedTime: 126.0,
            pendingSeekTargetTime: 120.0,
            elapsedSinceSeek: 2.0,
            playbackState: .buffering
        )

        XCTAssertFalse(shouldGate)
    }

    func testContiguousBufferedRangeEndReturnsRangeEndWhenPlaybackInsideRange() throws {
        let ranges = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600)),
        ]

        let rangeEnd = PlaybackService.contiguousBufferedRangeEnd(
            ranges: ranges,
            playbackTime: 12
        )

        let unwrappedRangeEnd = try XCTUnwrap(rangeEnd)
        XCTAssertEqual(unwrappedRangeEnd, 20, accuracy: 0.001)
    }

    func testContiguousBufferedRangeEndReturnsNilWhenPlaybackInGap() {
        let ranges = [
            CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600)),
            CMTimeRange(start: CMTime(seconds: 40, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600)),
        ]

        let rangeEnd = PlaybackService.contiguousBufferedRangeEnd(
            ranges: ranges,
            playbackTime: 30
        )

        XCTAssertNil(rangeEnd)
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

    func testPruneDuplicateFutureAutoplayItemsRemovesAlternateAlbumVersion() {
        let current = QueueItem(
            id: "current",
            track: makeTrack(id: "12728", title: "Telephone", artist: "Lady Gaga", duration: 221.0),
            source: .continuePlaying
        )
        let manualTeeth = QueueItem(
            id: "manual-teeth",
            track: makeTrack(id: "12730", title: "Teeth", artist: "Lady Gaga", duration: 220.693),
            source: .continuePlaying
        )
        let duplicateAutoplayTeeth = QueueItem(
            id: "duplicate-teeth",
            track: makeTrack(id: "11979", title: "Teeth", artist: "Lady Gaga", duration: 220.693),
            source: .autoplay
        )
        let bang = QueueItem(
            id: "bang",
            track: makeTrack(id: "11980", title: "Bang!", artist: "AJR", duration: 170),
            source: .autoplay
        )

        let result = PlaybackService.pruneDuplicateFutureAutoplayItems(
            queue: [current, manualTeeth, duplicateAutoplayTeeth, bang],
            currentQueueIndex: 0
        )

        XCTAssertEqual(result.queue.map(\.id), ["current", "manual-teeth", "bang"])
        XCTAssertEqual(result.removedTrackIds, [duplicateAutoplayTeeth.track.playbackIdentity])
        XCTAssertEqual(result.removedItemCount, 1)
    }

    func testPruneDuplicateFutureAutoplayItemsKeepsManualDuplicates() {
        let current = QueueItem(
            id: "current",
            track: makeTrack(id: "12728", title: "Telephone", artist: "Lady Gaga", duration: 221.0),
            source: .continuePlaying
        )
        let manualTeeth = QueueItem(
            id: "manual-teeth",
            track: makeTrack(id: "12730", title: "Teeth", artist: "Lady Gaga", duration: 220.693),
            source: .continuePlaying
        )
        let alternateManualTeeth = QueueItem(
            id: "alternate-manual-teeth",
            track: makeTrack(id: "11979", title: "Teeth", artist: "Lady Gaga", duration: 220.693),
            source: .continuePlaying
        )

        let result = PlaybackService.pruneDuplicateFutureAutoplayItems(
            queue: [current, manualTeeth, alternateManualTeeth],
            currentQueueIndex: 0
        )

        XCTAssertEqual(result.queue.map(\.id), ["current", "manual-teeth", "alternate-manual-teeth"])
        XCTAssertTrue(result.removedTrackIds.isEmpty)
        XCTAssertEqual(result.removedItemCount, 0)
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
}
