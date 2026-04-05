import EnsembleCore
import SwiftUI

/// Compact circular profile image button for toolbar placement.
/// Shows the user's profile picture (28×28pt) or a placeholder icon.
/// On tap, opens the profile sheet via NavigationCoordinator.
public struct ProfileToolbarButton: View {
    @ObservedObject private var profileStore: UserProfileStore
    private let navigationCoordinator: NavigationCoordinator

    public init(
        profileStore: UserProfileStore = DependencyContainer.shared.userProfileStore,
        navigationCoordinator: NavigationCoordinator = DependencyContainer.shared.navigationCoordinator
    ) {
        self.profileStore = profileStore
        self.navigationCoordinator = navigationCoordinator
    }

    public var body: some View {
        Button {
            navigationCoordinator.openProfile()
        } label: {
            profileImage
        }
        .help("Profile")
    }

    @ViewBuilder
    private var profileImage: some View {
        if let imageURL = profileStore.profileImageURL {
            LocalToolbarProfileImage(url: imageURL)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.circle")
                .font(.title3)
        }
    }
}

/// Loads a small profile image for toolbar display using platform-native APIs
private struct LocalToolbarProfileImage: View {
    let url: URL
    @State private var image: Image?

    var body: some View {
        Group {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.circle")
                    .font(.title3)
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _ in loadImage() }
    }

    private func loadImage() {
        #if canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: url.path) {
            image = Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(contentsOf: url) {
            image = Image(nsImage: nsImage)
        }
        #endif
    }
}
