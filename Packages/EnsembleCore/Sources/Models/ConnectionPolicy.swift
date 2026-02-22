import EnsembleAPI
import Foundation

/// Re-export API policy types for Core/UI usage.
public typealias PlexEndpointDescriptor = EnsembleAPI.PlexEndpointDescriptor
public typealias ConnectionSelectionPolicy = EnsembleAPI.ConnectionSelectionPolicy
public typealias AllowInsecureConnectionsPolicy = EnsembleAPI.AllowInsecureConnectionsPolicy

public extension AllowInsecureConnectionsPolicy {
    static let `defaultForEnsemble`: Self = .sameNetwork

    var title: String {
        switch self {
        case .sameNetwork:
            return "Preferred Local Fallback"
        case .never:
            return "Always Secure"
        case .always:
            return "Allow Insecure Everywhere"
        }
    }

    var subtitle: String {
        switch self {
        case .sameNetwork:
            return "Use secure endpoints first, allow local HTTP when needed."
        case .never:
            return "Only HTTPS endpoints are allowed."
        case .always:
            return "Use HTTP and HTTPS endpoints across local and remote paths."
        }
    }
}
