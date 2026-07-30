import EnsembleCore
import SwiftUI

/// Compact profile menu for toolbar placement.
/// Provides device-local library visibility controls and opens Settings.
public struct ProfileToolbarButton: View {
    @ObservedObject private var profileStore: UserProfileStore
    @ObservedObject private var accountManager: AccountManager
    @ObservedObject private var visibilityStore: LibraryVisibilityStore
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(
        profileStore: UserProfileStore = DependencyContainer.shared.userProfileStore,
        accountManager: AccountManager = DependencyContainer.shared.accountManager,
        visibilityStore: LibraryVisibilityStore = DependencyContainer.shared.libraryVisibilityStore
    ) {
        self.profileStore = profileStore
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore
    }

    public var body: some View {
        Menu {
            Button {
                navigationCoordinator.openProfile()
            } label: {
                Label("Settings", systemImage: EnsembleDesign.Icon.settings)
            }

            Divider()

            ForEach(accountManager.plexAccounts) { account in
                ForEach(account.servers) { server in
                    if server.libraries.contains(where: \.isEnabled) {
                        Section(server.name) {
                            ForEach(server.libraries.filter(\.isEnabled)) { library in
                                sourceToggle(
                                    library.title,
                                    source: MusicSourceIdentifier(
                                        type: .plex,
                                        accountId: account.id,
                                        serverId: server.id,
                                        libraryId: library.key
                                    )
                                )
                            }
                        }
                    }
                }
            }

            #if os(iOS)
            if accountManager.isAppleMusicEnabled {
                sourceToggle("Apple Music", source: .appleMusic)
            }
            #endif

            Divider()

            Button("Show All") {
                visibilityStore.setHiddenSourceCompositeKeys(
                    visibilityStore.hiddenSourceCompositeKeys.subtracting(enabledSourceKeys)
                )
            }
            .disabled(enabledSourceKeys.isDisjoint(with: visibilityStore.hiddenSourceCompositeKeys))

            Button("Hide All") {
                visibilityStore.setHiddenSourceCompositeKeys(
                    visibilityStore.hiddenSourceCompositeKeys.union(enabledSourceKeys)
                )
            }
            .disabled(enabledSourceKeys.isEmpty || enabledSourceKeys.isSubset(of: visibilityStore.hiddenSourceCompositeKeys))
        } label: {
            profileImage
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AutomationIdentifiers.Sidebar.profileToolbar)
        .help("Profile Focus")
    }

    private var enabledSourceKeys: Set<String> {
        Set(accountManager.enabledSources().map(\.compositeKey))
    }

    private func sourceToggle(_ title: String, source: MusicSourceIdentifier) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { !visibilityStore.hiddenSourceCompositeKeys.contains(source.compositeKey) },
                set: {
                    visibilityStore.setSourceVisibility(
                        sourceCompositeKey: source.compositeKey,
                        isVisible: $0
                    )
                }
            )
        )
    }

    @ViewBuilder
    private var profileImage: some View {
        if let imageURL = profileStore.profileImageURL {
            LocalProfileImage(
                url: imageURL,
                reloadToken: profileStore.profile.lastModified
            ) {
                toolbarPlaceholder
            }
                .frame(
                    width: EnsembleScaffold.ProfileToolbar.imageDimension,
                    height: EnsembleScaffold.ProfileToolbar.imageDimension
                )
                .clipShape(Circle())
        } else {
            toolbarPlaceholder
        }
    }

    private var toolbarPlaceholder: some View {
        Image(systemName: EnsembleDesign.Icon.profilePlaceholder)
            .font(EnsembleDesign.Typography.detailSubtitle)
    }
}
