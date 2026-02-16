import EnsembleCore
import SwiftUI

/// Banner that displays network connectivity status
public struct ConnectionStatusBanner: View {
    let networkState: NetworkState
    
    public init(networkState: NetworkState) {
        self.networkState = networkState
    }
    
    public var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .opacity(0.9)
                }
                
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(backgroundColor)
        }
    }
    
    private var shouldShow: Bool {
        switch networkState {
        case .offline, .limited:
            return true
        case .online, .unknown:
            return false
        }
    }
    
    private var backgroundColor: Color {
        switch networkState {
        case .offline:
            return Color.orange
        case .limited:
            return Color.yellow.opacity(0.9)
        case .online, .unknown:
            return Color.clear
        }
    }
    
    private var icon: String {
        switch networkState {
        case .offline:
            return "wifi.slash"
        case .limited:
            return "exclamationmark.triangle.fill"
        case .online, .unknown:
            return ""
        }
    }
    
    private var title: String {
        switch networkState {
        case .offline:
            return "No Connection"
        case .limited:
            return "Limited Connectivity"
        case .online, .unknown:
            return ""
        }
    }
    
    private var subtitle: String {
        switch networkState {
        case .offline:
            return "Using offline mode"
        case .limited:
            return "Some features may not work"
        case .online, .unknown:
            return ""
        }
    }
}
