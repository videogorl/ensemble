import EnsembleCore
import SwiftUI

public struct SettingsPresentationContainer: View {
    public init() {}

    public var body: some View {
        navigationContainer {
            SettingsView()
        }
    }
}

public struct DownloadsPresentationContainer: View {
    @StateObject private var nowPlayingVM: NowPlayingViewModel

    public init() {
        _nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
    }

    public var body: some View {
        navigationContainer {
            DownloadsView(nowPlayingVM: nowPlayingVM)
        }
    }
}

public struct AuxiliaryPresentationView: View {
    let destination: NavigationCoordinator.AuxiliaryPresentation

    public init(destination: NavigationCoordinator.AuxiliaryPresentation) {
        self.destination = destination
    }

    public var body: some View {
        switch destination {
        case .settings:
            SettingsPresentationContainer()
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
