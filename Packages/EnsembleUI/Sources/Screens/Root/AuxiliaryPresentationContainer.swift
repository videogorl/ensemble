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
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

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
    @StateObject private var nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public init() {
        _nowPlayingVM = StateObject(wrappedValue: DependencyContainer.shared.makeNowPlayingViewModel())
    }

    public var body: some View {
        #if os(macOS)
        MacAuxiliaryWindowScaffold(
            configuration: .downloads
        ) {
            DownloadsView(nowPlayingVM: nowPlayingVM)
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
        DownloadsView(nowPlayingVM: nowPlayingVM)
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
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

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
                    DownloadsPresentationContainer()
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
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    func body(content: Content) -> some View {
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
