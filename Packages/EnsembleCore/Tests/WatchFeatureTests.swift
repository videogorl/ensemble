import Combine
import XCTest
@testable import EnsembleCore

@MainActor
private func eventually(
    attempts: Int = 50,
    sleepNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: sleepNanoseconds)
    }

    return condition()
}

private func makeWatchTestTrack(id: String = "track-1") -> Track {
    Track(
        id: id,
        key: "/library/metadata/\(id)",
        title: "Track \(id)",
        artistName: "Artist",
        albumArtistName: "Artist",
        duration: 240,
        sourceCompositeKey: "plex:account:server:library"
    )
}

@MainActor
final class WatchConnectivityCoordinatorTests: XCTestCase {
    func testSendCommandDecodesRemoteSnapshotReply() async throws {
        let snapshot = WatchRemoteSessionSnapshot(
            currentTrack: makeWatchTestTrack(),
            playbackState: .playing,
            currentTime: 42,
            duration: 240,
            currentQueueIndex: 0,
            queueCount: 5,
            isShuffleEnabled: true,
            repeatModeRawValue: RepeatMode.all.rawValue,
            sourceName: "iPhone",
            updatedAt: Date(timeIntervalSince1970: 1_234)
        )

        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: { _ in
                let response = WatchRemoteCommandResponse(accepted: true, snapshot: snapshot)
                return ["response": try JSONEncoder().encode(response)]
            },
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )

        let response = await coordinator.send(command: WatchRemoteCommand(kind: .togglePlayPause))

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.snapshot, snapshot)
        XCTAssertEqual(coordinator.remoteSnapshot, snapshot)
    }

    func testSelectingRemoteTargetFallsBackWhenPhoneIsUnavailable() {
        var pushedContexts: [[String: Any]] = []
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: { pushedContexts.append($0) },
            activateHandler: nil,
            reachabilityProvider: { false }
        )

        coordinator.setSelectedPlaybackTarget(.iPhoneRemote)

        XCTAssertEqual(coordinator.selectedPlaybackTarget, .watchLocal)
        XCTAssertEqual(pushedContexts.count, 1)
        XCTAssertEqual(pushedContexts.first?["selectedTarget"] as? String, WatchPlaybackTarget.watchLocal.rawValue)
    }

    func testIncomingApplicationContextUpdatesSnapshot() throws {
        var reachable = true
        let snapshot = WatchRemoteSessionSnapshot(
            currentTrack: makeWatchTestTrack(id: "remote"),
            playbackState: .paused,
            currentTime: 12,
            duration: 120,
            currentQueueIndex: 2,
            queueCount: 6,
            isShuffleEnabled: false,
            repeatModeRawValue: RepeatMode.one.rawValue,
            sourceName: "iPhone",
            updatedAt: Date(timeIntervalSince1970: 2_468)
        )
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { reachable }
        )

        coordinator.handleIncomingApplicationContext([
            "snapshot": try JSONEncoder().encode(snapshot)
        ])

        XCTAssertEqual(coordinator.remoteSnapshot, snapshot)

        reachable = false
        coordinator.setSelectedPlaybackTarget(.iPhoneRemote)
        coordinator.handleIncomingApplicationContext([:])

        XCTAssertEqual(coordinator.selectedPlaybackTarget, .iPhoneRemote)
        XCTAssertFalse(coordinator.isPhoneReachable)
    }

    func testRemoteTargetRemainsAvailableWithCachedCompanionState() throws {
        let credentials = [
            SyncableAccountCredential(
                accountId: "account-1",
                email: "user@example.com",
                plexUsername: "user",
                displayTitle: "User",
                authToken: "token-1",
                servers: []
            )
        ]
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { false }
        )

        coordinator.handleIncomingApplicationContext([
            "syncCredentials": try JSONEncoder().encode(credentials)
        ])
        coordinator.setSelectedPlaybackTarget(.iPhoneRemote)

        XCTAssertTrue(coordinator.hasRemoteTargetAvailable)
        XCTAssertEqual(coordinator.selectedPlaybackTarget, .iPhoneRemote)
    }

    func testIncomingApplicationContextUpdatesCompanionCredentials() throws {
        let credentials = [
            SyncableAccountCredential(
                accountId: "account-1",
                email: "user@example.com",
                plexUsername: "user",
                displayTitle: "User",
                authToken: "token-1",
                servers: []
            )
        ]
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { false }
        )

        coordinator.handleIncomingApplicationContext([
            "syncCredentials": try JSONEncoder().encode(credentials)
        ])

        XCTAssertEqual(coordinator.companionCredentials, credentials)
    }

    func testIncomingCommandPayloadUsesCommandHandler() async throws {
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )
        coordinator.commandHandler = { command in
            XCTAssertEqual(command.kind, .next)
            return WatchRemoteCommandResponse(accepted: true)
        }

        let message = [
            "command": try JSONEncoder().encode(WatchRemoteCommand(kind: .next))
        ]
        let reply = await coordinator.processIncomingMessagePayload(message)
        let responseData = try XCTUnwrap(reply?["response"] as? Data)
        let response = try JSONDecoder().decode(WatchRemoteCommandResponse.self, from: responseData)

        XCTAssertTrue(response.accepted)
    }

    func testRequestCompanionCredentialsDecodesCredentialReply() async throws {
        let credentials = [
            SyncableAccountCredential(
                accountId: "account-1",
                email: "user@example.com",
                plexUsername: "user",
                displayTitle: "User",
                authToken: "token-1",
                servers: []
            )
        ]
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: { message in
                XCTAssertEqual(message["credentialRequest"] as? Bool, true)
                return ["syncCredentials": try JSONEncoder().encode(credentials)]
            },
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )

        let received = await coordinator.requestCompanionCredentials()

        XCTAssertEqual(received, credentials)
    }

    func testRequestCompanionCredentialsUsesCachedContextBeforeInteractiveMessaging() async throws {
        let credentials = [
            SyncableAccountCredential(
                accountId: "account-1",
                email: "user@example.com",
                plexUsername: "user",
                displayTitle: "User",
                authToken: "token-1",
                servers: []
            )
        ]
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: { _ in
                XCTFail("Interactive messaging should not be used when cached credentials are available.")
                return [:]
            },
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { false }
        )
        coordinator.handleIncomingApplicationContext([
            "syncCredentials": try JSONEncoder().encode(credentials)
        ])

        let received = await coordinator.requestCompanionCredentials()

        XCTAssertEqual(received, credentials)
    }

    func testIncomingCredentialRequestUsesCredentialProvider() async throws {
        let credentials = [
            SyncableAccountCredential(
                accountId: "account-1",
                email: nil,
                plexUsername: "user",
                displayTitle: "User",
                authToken: "token-1",
                servers: []
            )
        ]
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )
        coordinator.syncCredentialProvider = { credentials }

        let reply = await coordinator.processIncomingMessagePayload(["credentialRequest": true])
        let credentialData = try XCTUnwrap(reply?["syncCredentials"] as? Data)
        let decoded = try JSONDecoder().decode([SyncableAccountCredential].self, from: credentialData)

        XCTAssertEqual(decoded, credentials)
    }
}

@MainActor
final class WatchBootstrapCoordinatorTests: XCTestCase {
    func testBootstrapWaitsForAuthenticationWithoutSources() async {
        var accountLoaderCalls = 0
        let coordinator = WatchBootstrapCoordinator(
            accountLoader: { accountLoaderCalls += 1 },
            hasAnySources: { false },
            loadCompanionSources: { false },
            hasSyncedCredentials: { false },
            loadSyncedSources: { false },
            synchronizeKVS: XCTFailingVoidAction("KVS sync should not run without sources."),
            waitForInitialKVS: XCTFailingBoolAction("KVS wait should not run without sources."),
            pullAllKVS: XCTFailingVoidAction("KVS pull should not run without sources."),
            refreshProviders: XCTFailingVoidAction("Provider refresh should not run without sources."),
            startNetworkMonitor: XCTFailingVoidAction("Network monitor should not start without sources."),
            performHealthChecks: XCTFailingAsyncVoidAction("Health checks should not run without sources."),
            performStartupSync: XCTFailingAsyncVoidAction("Startup sync should not run without sources."),
            activateConnectivity: {}
        )

        coordinator.bootstrapIfNeeded()

        let reachedAwaitingAuthentication = await eventually { coordinator.phase == .awaitingAuthentication }
        XCTAssertTrue(reachedAwaitingAuthentication)
        XCTAssertEqual(accountLoaderCalls, 1)
        XCTAssertFalse(coordinator.hasCompletedInitialBootstrap)
        XCTAssertTrue(coordinator.requiresAuthentication)
    }

    func testBootstrapLoadsSyncedSourcesAndRunsStartupWork() async {
        var hasSources = false
        var loadCompanionSourcesCalls = 0
        var loadSyncedSourcesCalls = 0
        var synchronizeKVSCalls = 0
        var refreshProvidersCalls = 0
        var startNetworkMonitorCalls = 0
        var healthCheckCalls = 0
        var startupSyncCalls = 0

        let coordinator = WatchBootstrapCoordinator(
            accountLoader: {},
            hasAnySources: { hasSources },
            loadCompanionSources: {
                loadCompanionSourcesCalls += 1
                return false
            },
            hasSyncedCredentials: { true },
            loadSyncedSources: {
                loadSyncedSourcesCalls += 1
                hasSources = true
                return true
            },
            synchronizeKVS: { synchronizeKVSCalls += 1 },
            waitForInitialKVS: { true },
            pullAllKVS: {},
            refreshProviders: { refreshProvidersCalls += 1 },
            startNetworkMonitor: { startNetworkMonitorCalls += 1 },
            performHealthChecks: { healthCheckCalls += 1 },
            performStartupSync: { startupSyncCalls += 1 },
            activateConnectivity: {}
        )

        coordinator.bootstrapIfNeeded()

        let reachedReady = await eventually { coordinator.phase == .ready }
        XCTAssertTrue(reachedReady)
        XCTAssertTrue(coordinator.hasCompletedInitialBootstrap)
        XCTAssertEqual(loadCompanionSourcesCalls, 1)
        XCTAssertEqual(loadSyncedSourcesCalls, 1)
        XCTAssertEqual(synchronizeKVSCalls, 1)
        XCTAssertEqual(refreshProvidersCalls, 2)
        XCTAssertEqual(startNetworkMonitorCalls, 1)
        XCTAssertEqual(healthCheckCalls, 1)
        XCTAssertEqual(startupSyncCalls, 1)
    }

    func testRefreshAfterAuthenticationForcesAnotherStartupSync() async {
        var healthCheckCalls = 0
        var startupSyncCalls = 0

        let coordinator = WatchBootstrapCoordinator(
            accountLoader: {},
            hasAnySources: { true },
            loadCompanionSources: { false },
            hasSyncedCredentials: { false },
            loadSyncedSources: { false },
            synchronizeKVS: {},
            waitForInitialKVS: { true },
            pullAllKVS: {},
            refreshProviders: {},
            startNetworkMonitor: {},
            performHealthChecks: { healthCheckCalls += 1 },
            performStartupSync: { startupSyncCalls += 1 },
            activateConnectivity: {}
        )

        coordinator.bootstrapIfNeeded()
        let firstBootstrapCompleted = await eventually { coordinator.phase == .ready }
        XCTAssertTrue(firstBootstrapCompleted)
        XCTAssertEqual(healthCheckCalls, 1)
        XCTAssertEqual(startupSyncCalls, 1)

        coordinator.refreshAfterAuthentication()

        let forcedRefreshCompleted = await eventually(attempts: 100) {
            healthCheckCalls == 2 && startupSyncCalls == 2 && coordinator.phase == .ready
        }
        XCTAssertTrue(forcedRefreshCompleted)
    }

    func testBootstrapPrefersCompanionSourcesBeforeICloudFallback() async {
        var hasSources = false
        var loadCompanionSourcesCalls = 0
        var loadSyncedSourcesCalls = 0

        let coordinator = WatchBootstrapCoordinator(
            accountLoader: {},
            hasAnySources: { hasSources },
            loadCompanionSources: {
                loadCompanionSourcesCalls += 1
                hasSources = true
                return true
            },
            hasSyncedCredentials: { true },
            loadSyncedSources: {
                loadSyncedSourcesCalls += 1
                return true
            },
            synchronizeKVS: {},
            waitForInitialKVS: { true },
            pullAllKVS: {},
            refreshProviders: {},
            startNetworkMonitor: {},
            performHealthChecks: {},
            performStartupSync: {},
            activateConnectivity: {}
        )

        coordinator.bootstrapIfNeeded()

        let reachedReady = await eventually { coordinator.phase == .ready }
        XCTAssertTrue(reachedReady)
        XCTAssertEqual(loadCompanionSourcesCalls, 1)
        XCTAssertEqual(loadSyncedSourcesCalls, 0)
    }

    func testBootstrapRecoversWhenSourcesArriveAfterAuthenticationGate() async {
        var hasSources = false
        var healthCheckCalls = 0
        var startupSyncCalls = 0

        let coordinator = WatchBootstrapCoordinator(
            accountLoader: {},
            hasAnySources: { hasSources },
            loadCompanionSources: { false },
            hasSyncedCredentials: { false },
            loadSyncedSources: { false },
            synchronizeKVS: {},
            waitForInitialKVS: { true },
            pullAllKVS: {},
            refreshProviders: {},
            startNetworkMonitor: {},
            performHealthChecks: { healthCheckCalls += 1 },
            performStartupSync: { startupSyncCalls += 1 },
            activateConnectivity: {}
        )

        coordinator.bootstrapIfNeeded()
        let reachedAwaitingAuthentication = await eventually { coordinator.phase == .awaitingAuthentication }
        XCTAssertTrue(reachedAwaitingAuthentication)

        hasSources = true

        let recovered = await eventually(attempts: 150, sleepNanoseconds: 50_000_000) {
            coordinator.phase == .ready && healthCheckCalls == 1 && startupSyncCalls == 1
        }
        XCTAssertTrue(recovered)
    }
}

@MainActor
final class WatchPlaybackHubTests: XCTestCase {
    func testRemoteSnapshotDrivesDisplayedTrackWhenRemoteTargetSelected() async {
        let playbackService = PlaybackServiceSpy()
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )
        let hub = WatchPlaybackHub(
            localPlaybackService: playbackService,
            connectivityCoordinator: coordinator
        )
        let snapshot = WatchRemoteSessionSnapshot(
            currentTrack: makeWatchTestTrack(id: "remote-track"),
            playbackState: .playing,
            currentTime: 88,
            duration: 240,
            currentQueueIndex: 1,
            queueCount: 4,
            isShuffleEnabled: true,
            repeatModeRawValue: RepeatMode.all.rawValue,
            sourceName: "iPhone",
            updatedAt: Date(timeIntervalSince1970: 4_242)
        )

        coordinator.publishRemoteSnapshot(snapshot)
        coordinator.setSelectedPlaybackTarget(.iPhoneRemote)

        let remoteSnapshotApplied = await eventually {
            hub.selectedTarget == .iPhoneRemote && hub.currentTrack?.id == "remote-track"
        }
        XCTAssertTrue(remoteSnapshotApplied)
        XCTAssertEqual(hub.playbackState, .playing)
        XCTAssertEqual(hub.queueCount, 4)
        XCTAssertEqual(hub.repeatMode, .all)
        XCTAssertTrue(hub.isShuffleEnabled)
    }

    func testSelectingRemoteTargetFallsBackWhenPhoneIsUnavailable() {
        let hub = WatchPlaybackHub(
            localPlaybackService: PlaybackServiceSpy(),
            connectivityCoordinator: WatchConnectivityCoordinator(
                isSupported: true,
                messageSender: nil,
                contextUpdater: nil,
                activateHandler: nil,
                reachabilityProvider: { false }
            )
        )

        hub.selectTarget(.iPhoneRemote)

        XCTAssertEqual(hub.selectedTarget, .watchLocal)
        XCTAssertEqual(hub.availableTargets, [.watchLocal])
    }

    func testRemoteSnapshotAutoSelectsPhoneTargetWhenLocalPlaybackIsIdle() async throws {
        let playbackService = PlaybackServiceSpy()
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { false }
        )
        let hub = WatchPlaybackHub(
            localPlaybackService: playbackService,
            connectivityCoordinator: coordinator
        )
        let snapshot = WatchRemoteSessionSnapshot(
            currentTrack: makeWatchTestTrack(id: "remote-track"),
            playbackState: .playing,
            currentTime: 15,
            duration: 240,
            currentQueueIndex: 0,
            queueCount: 2,
            isShuffleEnabled: false,
            repeatModeRawValue: RepeatMode.off.rawValue,
            sourceName: "iPhone",
            updatedAt: Date(timeIntervalSince1970: 9_999)
        )

        coordinator.handleIncomingApplicationContext([
            "snapshot": try JSONEncoder().encode(snapshot)
        ])

        let autoSelectedRemote = await eventually {
            hub.selectedTarget == .iPhoneRemote && hub.currentTrack?.id == "remote-track"
        }
        XCTAssertTrue(autoSelectedRemote)
        XCTAssertTrue(hub.hasRemoteTargetAvailable)
    }

    func testLocalTogglePlayPauseUsesPlaybackService() async {
        let playbackService = PlaybackServiceSpy()
        playbackService.setPlaybackState(.playing)
        let hub = WatchPlaybackHub(
            localPlaybackService: playbackService,
            connectivityCoordinator: WatchConnectivityCoordinator(
                isSupported: true,
                messageSender: nil,
                contextUpdater: nil,
                activateHandler: nil,
                reachabilityProvider: { false }
            )
        )
        let observedPlayingState = await eventually { hub.playbackState == .playing }

        XCTAssertTrue(observedPlayingState)

        hub.togglePlayPause()

        XCTAssertEqual(playbackService.pauseCallCount, 1)
    }

    func testRemoteTogglePlayPauseSendsConnectivityCommand() async throws {
        var sentCommands: [WatchRemoteCommand] = []
        let playbackService = PlaybackServiceSpy()
        let coordinator = WatchConnectivityCoordinator(
            isSupported: true,
            messageSender: { message in
                let commandData = try XCTUnwrap(message["command"] as? Data)
                let command = try JSONDecoder().decode(WatchRemoteCommand.self, from: commandData)
                sentCommands.append(command)
                let response = WatchRemoteCommandResponse(accepted: true)
                return ["response": try JSONEncoder().encode(response)]
            },
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { true }
        )
        let hub = WatchPlaybackHub(
            localPlaybackService: playbackService,
            connectivityCoordinator: coordinator
        )

        hub.selectTarget(.iPhoneRemote)
        hub.togglePlayPause()

        let sentRemoteCommand = await eventually { sentCommands.count == 1 }
        XCTAssertTrue(sentRemoteCommand)
        XCTAssertEqual(sentCommands.first?.kind, .togglePlayPause)
        XCTAssertEqual(playbackService.pauseCallCount, 0)
    }
}

@MainActor
private func XCTFailingVoidAction(_ message: String) -> @MainActor () -> Void {
    { XCTFail(message) }
}

@MainActor
private func XCTFailingAsyncVoidAction(_ message: String) -> @MainActor () async -> Void {
    { XCTFail(message) }
}

@MainActor
private func XCTFailingBoolAction(_ message: String) -> @MainActor () async -> Bool {
    {
        XCTFail(message)
        return false
    }
}

@MainActor
private final class PlaybackServiceSpy: @preconcurrency PlaybackServiceProtocol {
    var currentTrack: Track?
    var playbackState: PlaybackState = .stopped
    var currentTime: TimeInterval = 0
    var presentationTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var queue: [QueueItem] = []
    var currentQueueIndex: Int = -1
    var isShuffleEnabled = false
    var repeatMode: RepeatMode = .off
    var waveformHeights: [Double] = []
    var frequencyBands: [Double] = []
    var isExternalPlaybackActive = false
    var isAutoplayEnabled = false
    var autoplayTracks: [Track] = []
    var isAutoplayActive = false
    var radioMode: RadioMode = .off
    var recommendationsExhausted = false
    var queueSections: QueueSections = .empty
    var playbackHistory: [QueueItem] = []
    var currentTimeValue: TimeInterval { currentTime }
    var presentationTimeValue: TimeInterval { presentationTime }
    var bufferedProgressValue: Double = 0
    var isInstrumentalModeActive = false
    var isScreenMirroringActive = false

    private let currentTrackSubject = CurrentValueSubject<Track?, Never>(nil)
    private let playbackStateSubject = CurrentValueSubject<PlaybackState, Never>(.stopped)
    private let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let presentationTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    private let queueSubject = CurrentValueSubject<[QueueItem], Never>([])
    private let currentQueueIndexSubject = CurrentValueSubject<Int, Never>(-1)
    private let shuffleSubject = CurrentValueSubject<Bool, Never>(false)
    private let repeatModeSubject = CurrentValueSubject<RepeatMode, Never>(.off)
    private let waveformSubject = CurrentValueSubject<[Double], Never>([])
    private let frequencyBandsSubject = CurrentValueSubject<[Double], Never>([])
    private let externalPlaybackSubject = CurrentValueSubject<Bool, Never>(false)
    private let autoplayEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    private let autoplayTracksSubject = CurrentValueSubject<[Track], Never>([])
    private let autoplayActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let radioModeSubject = CurrentValueSubject<RadioMode, Never>(.off)
    private let recommendationsExhaustedSubject = CurrentValueSubject<Bool, Never>(false)
    private let historySubject = CurrentValueSubject<[QueueItem], Never>([])
    private let instrumentalModeSubject = CurrentValueSubject<Bool, Never>(false)

    var pauseCallCount = 0

    var currentTrackPublisher: AnyPublisher<Track?, Never> { currentTrackSubject.eraseToAnyPublisher() }
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { playbackStateSubject.eraseToAnyPublisher() }
    var currentTimePublisher: AnyPublisher<TimeInterval, Never> { currentTimeSubject.eraseToAnyPublisher() }
    var presentationTimePublisher: AnyPublisher<TimeInterval, Never> { presentationTimeSubject.eraseToAnyPublisher() }
    var queuePublisher: AnyPublisher<[QueueItem], Never> { queueSubject.eraseToAnyPublisher() }
    var currentQueueIndexPublisher: AnyPublisher<Int, Never> { currentQueueIndexSubject.eraseToAnyPublisher() }
    var shufflePublisher: AnyPublisher<Bool, Never> { shuffleSubject.eraseToAnyPublisher() }
    var repeatModePublisher: AnyPublisher<RepeatMode, Never> { repeatModeSubject.eraseToAnyPublisher() }
    var waveformPublisher: AnyPublisher<[Double], Never> { waveformSubject.eraseToAnyPublisher() }
    var frequencyBandsPublisher: AnyPublisher<[Double], Never> { frequencyBandsSubject.eraseToAnyPublisher() }
    var isExternalPlaybackActivePublisher: AnyPublisher<Bool, Never> { externalPlaybackSubject.eraseToAnyPublisher() }
    var autoplayEnabledPublisher: AnyPublisher<Bool, Never> { autoplayEnabledSubject.eraseToAnyPublisher() }
    var autoplayTracksPublisher: AnyPublisher<[Track], Never> { autoplayTracksSubject.eraseToAnyPublisher() }
    var autoplayActivePublisher: AnyPublisher<Bool, Never> { autoplayActiveSubject.eraseToAnyPublisher() }
    var radioModePublisher: AnyPublisher<RadioMode, Never> { radioModeSubject.eraseToAnyPublisher() }
    var recommendationsExhaustedPublisher: AnyPublisher<Bool, Never> { recommendationsExhaustedSubject.eraseToAnyPublisher() }
    var historyPublisher: AnyPublisher<[QueueItem], Never> { historySubject.eraseToAnyPublisher() }
    var instrumentalModeActivePublisher: AnyPublisher<Bool, Never> { instrumentalModeSubject.eraseToAnyPublisher() }

    func setPlaybackState(_ newState: PlaybackState) {
        playbackState = newState
        playbackStateSubject.send(newState)
    }

    func play(track: Track) async {
        currentTrack = track
        duration = track.duration
        queue = [QueueItem(track: track)]
        currentQueueIndex = 0
        currentTrackSubject.send(track)
        queueSubject.send(queue)
        currentQueueIndexSubject.send(0)
        setPlaybackState(.playing)
    }

    func play(tracks: [Track], startingAt index: Int) async {
        queue = tracks.map { QueueItem(track: $0) }
        queueSubject.send(queue)
        currentQueueIndex = index
        currentQueueIndexSubject.send(index)
        if tracks.indices.contains(index) {
            currentTrack = tracks[index]
            duration = tracks[index].duration
            currentTrackSubject.send(tracks[index])
        }
        setPlaybackState(.playing)
    }

    func shufflePlay(tracks: [Track]) async {
        await play(tracks: tracks, startingAt: 0)
    }

    func playQueueIndex(_ index: Int) async {
        guard queue.indices.contains(index) else { return }
        currentQueueIndex = index
        currentQueueIndexSubject.send(index)
        currentTrack = queue[index].track
        currentTrackSubject.send(queue[index].track)
        duration = queue[index].track.duration
        setPlaybackState(.playing)
    }

    func pause() {
        pauseCallCount += 1
        setPlaybackState(.paused)
    }

    func resume() {
        setPlaybackState(.playing)
    }

    func stop() {
        setPlaybackState(.stopped)
    }

    func retryCurrentTrack() async {
        setPlaybackState(.playing)
    }

    func next() {
        currentQueueIndex += 1
        currentQueueIndexSubject.send(currentQueueIndex)
    }

    func previous() {
        currentQueueIndex = max(-1, currentQueueIndex - 1)
        currentQueueIndexSubject.send(currentQueueIndex)
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        currentTimeSubject.send(time)
    }

    func startFastSeeking(forward: Bool) {}
    func stopFastSeeking() {}

    func addToQueue(_ track: Track) {
        queue.append(QueueItem(track: track))
        queueSubject.send(queue)
    }

    func addToQueue(_ tracks: [Track]) {
        queue.append(contentsOf: tracks.map { QueueItem(track: $0) })
        queueSubject.send(queue)
    }

    func playNext(_ track: Track) {
        queue.insert(QueueItem(track: track, source: .upNext), at: min(max(currentQueueIndex + 1, 0), queue.count))
        queueSubject.send(queue)
    }

    func playNext(_ tracks: [Track]) {
        for track in tracks.reversed() {
            playNext(track)
        }
    }

    func playLast(_ track: Track) {
        queue.append(QueueItem(track: track))
        queueSubject.send(queue)
    }

    func playLast(_ tracks: [Track]) {
        addToQueue(tracks)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        queueSubject.send(queue)
    }

    func clearQueue() {
        queue = []
        queueSubject.send([])
        currentQueueIndex = -1
        currentQueueIndexSubject.send(-1)
    }

    func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int) {}
    func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {}

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        shuffleSubject.send(isShuffleEnabled)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        repeatModeSubject.send(repeatMode)
    }

    func toggleAutoplay() {}
    func refreshAutoplayQueue() async {}
    func enableRadio(tracks: [Track]) async {}
    func playArtistRadio(for artist: Artist) async {}
    func playAlbumRadio(for album: Album) async {}
    func isTrackAutoGenerated(trackId: String) -> Bool { false }
    func playFromHistory(at historyIndex: Int) async {}
    func applyRatingLocally(trackId: String, rating: Int) async {}
    func updateVisualizerPosition(_ time: TimeInterval) {}
    func currentPlaybackFileInfo() -> (codec: String?, fileSize: Int64?) { (nil, nil) }
    func setInstrumentalMode(_ enabled: Bool) {
        isInstrumentalModeActive = enabled
        instrumentalModeSubject.send(enabled)
    }
}
