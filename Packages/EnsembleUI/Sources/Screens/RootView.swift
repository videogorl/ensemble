import EnsembleCore
import SwiftUI

/// Root view that handles authentication state and platform-adaptive navigation
public struct RootView: View {
    @StateObject private var authViewModel: AuthViewModel

    public init() {
        self._authViewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAuthViewModel())
    }

    public var body: some View {
        Group {
            switch authViewModel.authState {
            case .unknown:
                loadingView

            case .unauthenticated, .authenticating:
                LoginView(viewModel: authViewModel)

            case .selectingServer:
                LoginView(viewModel: authViewModel)

            case .authenticated:
                mainContentView
            }
        }
        .task {
            await authViewModel.checkAuthState()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var mainContentView: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            SidebarView(authViewModel: authViewModel)
        } else {
            MainTabView(authViewModel: authViewModel)
        }
        #elseif os(macOS)
        SidebarView(authViewModel: authViewModel)
        #else
        MainTabView(authViewModel: authViewModel)
        #endif
    }
}
