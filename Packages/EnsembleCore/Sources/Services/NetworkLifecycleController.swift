import Foundation

/// Owns app-foreground and network-transition policy so SyncCoordinator can
/// apply a plan instead of classifying lifecycle events inline.
@MainActor
final class NetworkLifecycleController {
    enum NetworkTransition: Equatable {
        case reconnect
        case interfaceSwitch(from: NetworkType, to: NetworkType)
        case disconnect
        case none

        var logDescription: String {
            switch self {
            case .reconnect:
                return "reconnect"
            case .interfaceSwitch(let from, let to):
                return "interfaceSwitch(\(from.description)->\(to.description))"
            case .disconnect:
                return "disconnect"
            case .none:
                return "none"
            }
        }
    }

    struct ForegroundDecision: Equatable {
        let offlineValue: Bool?
        let healthRefreshRequest: RefreshOrchestrator.HealthRefreshRequest?

        var diagnosticSummary: String {
            [
                "offline=\(offlineValue.map(String.init(describing:)) ?? "nil")",
                "refresh=\(healthRefreshRequest?.reason.description ?? "none")",
                "force=\(healthRefreshRequest?.forceServerRefresh == true ? 1 : 0)"
            ].joined(separator: " ")
        }
    }

    struct ObservedDecision: Equatable {
        let previousState: NetworkState?
        let transition: NetworkTransition
        let offlineValue: Bool?
        let shouldInvalidateConnectionHealth: Bool
        let shouldInvalidateArtworkConnections: Bool
        let healthRefreshRequest: RefreshOrchestrator.HealthRefreshRequest?
        let skippedAsInitialTransition: Bool

        var diagnosticSummary: String {
            [
                "from=\(previousState?.description ?? "nil")",
                "transition=\(transition.logDescription)",
                "offline=\(offlineValue.map(String.init(describing:)) ?? "nil")",
                "invalidateConnections=\(shouldInvalidateConnectionHealth ? 1 : 0)",
                "invalidateArtwork=\(shouldInvalidateArtworkConnections ? 1 : 0)",
                "refresh=\(healthRefreshRequest?.reason.description ?? "none")",
                "force=\(healthRefreshRequest?.forceServerRefresh == true ? 1 : 0)",
                "initialSkip=\(skippedAsInitialTransition ? 1 : 0)"
            ].joined(separator: " ")
        }
    }

    private var lastObservedNetworkState: NetworkState?
    private var hasCompletedInitialNetworkTransition = false

    init(initialNetworkState: NetworkState? = nil) {
        self.lastObservedNetworkState = initialNetworkState
    }

    func foregroundDecision(for state: NetworkState) -> ForegroundDecision {
        switch state {
        case .online:
            return ForegroundDecision(
                offlineValue: false,
                healthRefreshRequest: .init(reason: .appForeground, forceServerRefresh: false)
            )
        case .offline, .limited:
            return ForegroundDecision(
                offlineValue: true,
                healthRefreshRequest: nil
            )
        case .unknown:
            return ForegroundDecision(
                offlineValue: nil,
                healthRefreshRequest: nil
            )
        }
    }

    func observeNetworkState(_ state: NetworkState) -> ObservedDecision {
        let previous = lastObservedNetworkState
        lastObservedNetworkState = state

        let transition = classifyNetworkTransition(from: previous, to: state)
        let offlineValue: Bool?
        switch state {
        case .online:
            offlineValue = false
        case .offline, .limited:
            offlineValue = true
        case .unknown:
            offlineValue = nil
        }

        if !hasCompletedInitialNetworkTransition, previous == .unknown || previous == nil {
            if state.isConnected {
                hasCompletedInitialNetworkTransition = true
                return ObservedDecision(
                    previousState: previous,
                    transition: transition,
                    offlineValue: offlineValue,
                    shouldInvalidateConnectionHealth: false,
                    shouldInvalidateArtworkConnections: false,
                    healthRefreshRequest: nil,
                    skippedAsInitialTransition: true
                )
            }
        }

        let shouldInvalidateConnectionHealth: Bool
        let shouldInvalidateArtworkConnections: Bool
        let healthRefreshRequest: RefreshOrchestrator.HealthRefreshRequest?

        switch transition {
        case .reconnect:
            shouldInvalidateConnectionHealth = true
            shouldInvalidateArtworkConnections = true
            healthRefreshRequest = .init(reason: .networkReconnect, forceServerRefresh: true)
        case .interfaceSwitch(let from, let to):
            shouldInvalidateConnectionHealth = true
            shouldInvalidateArtworkConnections = true
            healthRefreshRequest = .init(reason: .interfaceSwitch(from: from, to: to), forceServerRefresh: true)
        case .disconnect, .none:
            shouldInvalidateConnectionHealth = false
            shouldInvalidateArtworkConnections = false
            healthRefreshRequest = nil
        }

        return ObservedDecision(
            previousState: previous,
            transition: transition,
            offlineValue: offlineValue,
            shouldInvalidateConnectionHealth: shouldInvalidateConnectionHealth,
            shouldInvalidateArtworkConnections: shouldInvalidateArtworkConnections,
            healthRefreshRequest: healthRefreshRequest,
            skippedAsInitialTransition: false
        )
    }

    private func classifyNetworkTransition(from previous: NetworkState?, to current: NetworkState) -> NetworkTransition {
        let previousType = networkType(from: previous)
        let currentType = networkType(from: current)
        let previousConnected = previous?.isConnected ?? false
        let currentConnected = current.isConnected

        if !previousConnected && currentConnected {
            return .reconnect
        }

        if previousConnected && !currentConnected {
            return .disconnect
        }

        if let previousType, let currentType, previousType != currentType {
            return .interfaceSwitch(from: previousType, to: currentType)
        }

        return .none
    }

    private func networkType(from state: NetworkState?) -> NetworkType? {
        guard let state, case .online(let type) = state else {
            return nil
        }
        return type
    }
}
