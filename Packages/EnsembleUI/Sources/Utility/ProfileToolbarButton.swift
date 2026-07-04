import EnsembleCore
import SwiftUI

/// Compact profile image button for toolbar placement.
/// Shows the user's profile picture (28×28pt) or a placeholder icon.
/// On tap, opens the profile sheet via NavigationCoordinator.
public struct ProfileToolbarButton: View {
    @ObservedObject private var profileStore: UserProfileStore
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(
        profileStore: UserProfileStore = DependencyContainer.shared.userProfileStore
    ) {
        self.profileStore = profileStore
    }

    public var body: some View {
        Button {
            navigationCoordinator.openProfile()
        } label: {
            profileImage
        }
        .buttonStyle(.plain)
        .help("Profile")
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
