import EnsembleCore
import SwiftUI

private struct AuxiliaryDismissToolbarModifier: ViewModifier {
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        navigationCoordinator.dismissAuxiliaryPresentation()
                    }
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public struct ProfilePresentationContainer: View {
    public init() {}

    public var body: some View {
        #if os(macOS)
        MacAuxiliaryWindowScaffold(
            maxWidth: 420,
            minHeight: 560
        ) {
            navigationContainer {
                ProfileView()
            }
        }
        #else
        navigationContainer {
            ProfileView()
                .modifier(AuxiliaryDismissToolbarModifier())
        }
        #endif
    }
}

/// Legacy alias for backwards compatibility
public typealias SettingsPresentationContainer = ProfilePresentationContainer

public struct DownloadsPresentationContainer: View {
    @StateObject private var nowPlayingVM: NowPlayingViewModel

    public init() {
        _nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
    }

    public var body: some View {
        #if os(macOS)
        MacAuxiliaryWindowScaffold(
            maxWidth: 420,
            minHeight: 640
        ) {
            navigationContainer {
                DownloadsView(nowPlayingVM: nowPlayingVM)
            }
        }
        #else
        navigationContainer {
            DownloadsView(nowPlayingVM: nowPlayingVM)
                .modifier(AuxiliaryDismissToolbarModifier())
        }
        #endif
    }
}

public struct AuxiliaryPresentationView: View {
    let destination: NavigationCoordinator.AuxiliaryPresentation

    public init(destination: NavigationCoordinator.AuxiliaryPresentation) {
        self.destination = destination
    }

    public var body: some View {
        switch destination {
        case .profile:
            ProfilePresentationContainer()
        case .downloads:
            DownloadsPresentationContainer()
        }
    }
}

@ViewBuilder
private func navigationContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 16.0, macOS 13.0, *) {
        NavigationStack {
            content()
        }
    } else {
        NavigationView {
            content()
        }
        #if os(iOS)
        .navigationViewStyle(.stack)
        #endif
    }
}
