import EnsembleCore
import SwiftUI

private struct AuxiliaryDismissToolbarModifier: ViewModifier {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

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
    @Environment(DependencyContainer.self) private var dependencies
    private var settingsManager: SettingsManager { dependencies.settingsManager }

    public init() {}

    public var body: some View {
        #if os(macOS)
        MacAuxiliaryWindowScaffold(
            configuration: .profile
        ) {
            ProfileView()
                .nativeSheetNavigationContainer()
        }
        .accentColor(settingsManager.accentColor.color)
        #else
        ProfileView()
            .modifier(AuxiliaryDismissToolbarModifier())
            .nativeSheetNavigationContainer()
            .accentColor(settingsManager.accentColor.color)
        #endif
    }
}

public struct DownloadsPresentationContainer: View {
    @Environment(DependencyContainer.self) private var dependencies
    @StateObject private var holder: NowPlayingHolder
    private var settingsManager: SettingsManager { dependencies.settingsManager }

    public init(dependencies: DependencyContainer) {
        _holder = StateObject(wrappedValue: NowPlayingHolder(dependencies: dependencies))
    }

    private var nowPlayingVM: NowPlayingViewModel { holder.nowPlaying }

    public var body: some View {
        #if os(macOS)
        MacAuxiliaryWindowScaffold(
            configuration: .downloads
        ) {
            DownloadsView(nowPlayingVM: nowPlayingVM, dependencies: dependencies)
                .nativeSheetNavigationContainer()
        }
        .accentColor(settingsManager.accentColor.color)
        .alert("Replace Queue?", isPresented: queueReplacementConfirmationBinding) {
            Button("Cancel", role: .cancel) {
                nowPlayingVM.cancelQueueReplacement()
            }
            Button("Clear Queue and Play", role: .destructive) {
                nowPlayingVM.confirmQueueReplacement()
            }
        } message: {
            Text("This will replace the songs you added to the current queue.")
        }
        #else
        DownloadsView(nowPlayingVM: nowPlayingVM, dependencies: dependencies)
            .modifier(AuxiliaryDismissToolbarModifier())
            .nativeSheetNavigationContainer()
            .accentColor(settingsManager.accentColor.color)
            .alert("Replace Queue?", isPresented: queueReplacementConfirmationBinding) {
                Button("Cancel", role: .cancel) {
                    nowPlayingVM.cancelQueueReplacement()
                }
                Button("Clear Queue and Play", role: .destructive) {
                    nowPlayingVM.confirmQueueReplacement()
                }
            } message: {
                Text("This will replace the songs you added to the current queue.")
            }
        #endif
    }

    private var queueReplacementConfirmationBinding: Binding<Bool> {
        Binding(
            get: { nowPlayingVM.isQueueReplacementConfirmationPresented },
            set: { isPresented in
                if !isPresented {
                    nowPlayingVM.cancelQueueReplacement()
                }
            }
        )
    }
}

private struct AuxiliaryPresentationSheetsModifier: ViewModifier {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(DependencyContainer.self) private var dependencies

    private var presentationBinding: Binding<NavigationCoordinator.AuxiliaryPresentation?> {
        Binding(
            get: { navigationCoordinator.activeAuxiliaryPresentation },
            set: { presentation in
                if let presentation {
                    navigationCoordinator.activeAuxiliaryPresentation = presentation
                } else {
                    navigationCoordinator.dismissAuxiliaryPresentation()
                }
            }
        )
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .sheet(item: presentationBinding) { presentation in
                switch presentation {
                case .profile:
                    ProfilePresentationContainer()
                case .downloads:
                    DownloadsPresentationContainer(dependencies: dependencies)
                }
            }
        #else
        content
        #endif
    }
}

public extension View {
    /// Presents root auxiliary profile/download sheets from the scene owner.
    func auxiliaryPresentationSheets() -> some View {
        modifier(AuxiliaryPresentationSheetsModifier())
    }
}

private struct AddAccountPresentationSheetModifier: ViewModifier {
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    func body(content: Content) -> some View {
        @Bindable var navigationCoordinator = navigationCoordinator
        content
            .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
                AddSourceView()
                #if os(macOS)
                    .frame(
                        width: EnsembleScaffold.AccountSetup.macMinimumWidth,
                        height: EnsembleScaffold.AccountSetup.macMinimumHeight
                    )
                #endif
            }
    }
}

public extension View {
    /// Presents the root add-account sheet from the active navigation shell.
    func addAccountPresentationSheet() -> some View {
        modifier(AddAccountPresentationSheetModifier())
    }
}

/// Builds the window's Now Playing model once; `@StateObject` gives the lazy,
/// once-per-window ownership that `@State` cannot on iOS 17.
@MainActor
private final class NowPlayingHolder: ObservableObject {
    let nowPlaying: NowPlayingViewModel

    init(dependencies: DependencyContainer) {
        nowPlaying = NowPlayingViewModel(dependencies: dependencies)
        nowPlaying.start()
    }
}
