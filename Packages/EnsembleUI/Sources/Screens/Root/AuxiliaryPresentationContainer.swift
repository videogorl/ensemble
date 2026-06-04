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
        #else
        DownloadsView(nowPlayingVM: nowPlayingVM)
            .modifier(AuxiliaryDismissToolbarModifier())
            .nativeSheetNavigationContainer()
            .accentColor(settingsManager.accentColor.color)
        #endif
    }
}

private struct AuxiliaryPresentationSheetsModifier: ViewModifier {
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    let accentColor: AppAccentColor

    private var profileSheetBinding: Binding<Bool> {
        Binding(
            get: { navigationCoordinator.activeAuxiliaryPresentation == .profile },
            set: { isPresented in
                guard !isPresented,
                      navigationCoordinator.activeAuxiliaryPresentation == .profile else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    private var downloadsSheetBinding: Binding<Bool> {
        Binding(
            get: { navigationCoordinator.activeAuxiliaryPresentation == .downloads },
            set: { isPresented in
                guard !isPresented,
                      navigationCoordinator.activeAuxiliaryPresentation == .downloads else { return }
                navigationCoordinator.dismissAuxiliaryPresentation()
            }
        )
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .sheet(isPresented: profileSheetBinding) {
                ProfilePresentationContainer()
                    .accentColor(accentColor.color)
            }
            .sheet(isPresented: downloadsSheetBinding) {
                DownloadsPresentationContainer()
                    .accentColor(accentColor.color)
            }
        #else
        content
        #endif
    }
}

public extension View {
    /// Presents root auxiliary profile/download sheets from the active root shell.
    func auxiliaryPresentationSheets(accentColor: AppAccentColor) -> some View {
        modifier(AuxiliaryPresentationSheetsModifier(accentColor: accentColor))
    }
}

private struct AddAccountPresentationSheetModifier: ViewModifier {
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $navigationCoordinator.showingAddAccount) {
                AddPlexAccountView()
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
