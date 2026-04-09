import Combine
import Foundation

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
import WatchConnectivity
#endif

@MainActor
public final class WatchConnectivityCoordinator: NSObject, ObservableObject {
    public typealias MessageSender = ([String: Any]) async throws -> [String: Any]
    public typealias ContextUpdater = ([String: Any]) throws -> Void

    private enum PayloadKey {
        static let command = "command"
        static let response = "response"
        static let snapshot = "snapshot"
        static let selectedTarget = "selectedTarget"
    }

    @Published public private(set) var isSupported: Bool
    @Published public private(set) var isPhoneReachable: Bool
    @Published public private(set) var remoteSnapshot: WatchRemoteSessionSnapshot?
    @Published public private(set) var selectedPlaybackTarget: WatchPlaybackTarget

    public var commandHandler: ((WatchRemoteCommand) async -> WatchRemoteCommandResponse)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let messageSender: MessageSender?
    private let contextUpdater: ContextUpdater?
    private let activateHandler: (() -> Void)?
    private let reachabilityProvider: () -> Bool
    private var lastPublishedSnapshot: WatchRemoteSessionSnapshot?

    public override convenience init() {
        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        let session = WCSession.isSupported() ? WCSession.default : nil
        self.init(
            isSupported: session != nil,
            messageSender: session.map { session in
                { message in
                    try await withCheckedThrowingContinuation { continuation in
                        session.sendMessage(message, replyHandler: { reply in
                            continuation.resume(returning: reply)
                        }, errorHandler: { error in
                            continuation.resume(throwing: error)
                        })
                    }
                }
            },
            contextUpdater: session.map { session in
                { context in
                    try session.updateApplicationContext(context)
                }
            },
            activateHandler: {
                session?.activate()
            },
            reachabilityProvider: {
                session?.isReachable ?? false
            }
        )
        #else
        self.init(
            isSupported: false,
            messageSender: nil,
            contextUpdater: nil,
            activateHandler: nil,
            reachabilityProvider: { false }
        )
        #endif
    }

    public init(
        isSupported: Bool,
        messageSender: MessageSender?,
        contextUpdater: ContextUpdater?,
        activateHandler: (() -> Void)?,
        reachabilityProvider: @escaping () -> Bool
    ) {
        self.isSupported = isSupported
        self.messageSender = messageSender
        self.contextUpdater = contextUpdater
        self.activateHandler = activateHandler
        self.reachabilityProvider = reachabilityProvider
        self.isPhoneReachable = reachabilityProvider()
        self.selectedPlaybackTarget = .watchLocal
        super.init()

        #if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
        if let session = WCSession.isSupported() ? WCSession.default : nil {
            session.delegate = self
            self.isPhoneReachable = session.isReachable
        }
        #endif
    }

    public func activate() {
        guard isSupported else { return }
        activateHandler?()
        refreshReachability()
    }

    public func refreshReachability() {
        isPhoneReachable = reachabilityProvider()
        if !isPhoneReachable, selectedPlaybackTarget == .iPhoneRemote {
            selectedPlaybackTarget = .watchLocal
        }
    }

    public func setSelectedPlaybackTarget(_ target: WatchPlaybackTarget) {
        guard target != .iPhoneRemote || isPhoneReachable else {
            selectedPlaybackTarget = .watchLocal
            publishLatestContext()
            return
        }
        selectedPlaybackTarget = target
        publishLatestContext()
    }

    public func publishRemoteSnapshot(_ snapshot: WatchRemoteSessionSnapshot) {
        remoteSnapshot = snapshot

        guard lastPublishedSnapshot != snapshot else {
            return
        }

        lastPublishedSnapshot = snapshot
        publishLatestContext()
    }

    public func send(command: WatchRemoteCommand) async -> WatchRemoteCommandResponse {
        guard isSupported else {
            return WatchRemoteCommandResponse(accepted: false, errorMessage: "Watch Connectivity is unavailable.")
        }

        guard isPhoneReachable else {
            return WatchRemoteCommandResponse(accepted: false, errorMessage: "The iPhone is unreachable.")
        }

        guard let messageSender else {
            return WatchRemoteCommandResponse(accepted: false, errorMessage: "Remote messaging is unavailable.")
        }

        do {
            let payload = try encoder.encode(command)
            let reply = try await messageSender([PayloadKey.command: payload])
            return try decodeResponse(from: reply)
        } catch {
            return WatchRemoteCommandResponse(accepted: false, errorMessage: error.localizedDescription)
        }
    }

    func handleIncomingApplicationContext(_ context: [String: Any]) {
        if let snapshotData = context[PayloadKey.snapshot] as? Data,
           let snapshot = try? decoder.decode(WatchRemoteSessionSnapshot.self, from: snapshotData) {
            remoteSnapshot = snapshot
        }

        refreshReachability()
    }

    func processIncomingMessagePayload(_ message: [String: Any]) async -> [String: Any]? {
        guard let commandHandler else { return nil }
        guard let commandData = message[PayloadKey.command] as? Data else { return nil }

        do {
            let command = try decoder.decode(WatchRemoteCommand.self, from: commandData)
            let response = await commandHandler(command)
            let responseData = try encoder.encode(response)
            return [PayloadKey.response: responseData]
        } catch {
            let fallback = WatchRemoteCommandResponse(
                accepted: false,
                errorMessage: error.localizedDescription,
                snapshot: remoteSnapshot
            )
            let responseData = try? encoder.encode(fallback)
            return responseData.map { [PayloadKey.response: $0] }
        }
    }

    private func decodeResponse(from reply: [String: Any]) throws -> WatchRemoteCommandResponse {
        guard let responseData = reply[PayloadKey.response] as? Data else {
            return WatchRemoteCommandResponse(accepted: false, errorMessage: "Missing remote response.")
        }

        let response = try decoder.decode(WatchRemoteCommandResponse.self, from: responseData)
        if let snapshot = response.snapshot {
            remoteSnapshot = snapshot
        }
        return response
    }

    private func publishLatestContext() {
        guard let contextUpdater else { return }

        var context: [String: Any] = [
            PayloadKey.selectedTarget: selectedPlaybackTarget.rawValue
        ]

        if let remoteSnapshot,
           let snapshotData = try? encoder.encode(remoteSnapshot) {
            context[PayloadKey.snapshot] = snapshotData
        }

        do {
            try contextUpdater(context)
        } catch {
            EnsembleLogger.debug("WatchConnectivityCoordinator: failed to update application context: \(error.localizedDescription)")
        }
    }
}

#if canImport(WatchConnectivity) && (os(iOS) || os(watchOS))
extension WatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.refreshReachability()
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.handleIncomingApplicationContext(applicationContext)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            let response = await self?.processIncomingMessagePayload(message) ?? [:]
            replyHandler(response)
        }
    }

    #if os(watchOS)
    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            if let error {
                EnsembleLogger.debug("WatchConnectivityCoordinator: activation failed on watchOS: \(error.localizedDescription)")
            }
            self?.refreshReachability()
        }
    }
    #endif

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            if let error {
                EnsembleLogger.debug("WatchConnectivityCoordinator: activation failed on iOS: \(error.localizedDescription)")
            }
            self?.refreshReachability()
        }
    }
    #endif
}
#endif
