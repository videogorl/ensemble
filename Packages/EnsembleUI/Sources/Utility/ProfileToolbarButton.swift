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
            LocalToolbarProfileImage(
                url: imageURL,
                reloadToken: profileStore.profile.lastModified
            )
                .frame(
                    width: EnsembleScaffold.ProfileToolbar.imageDimension,
                    height: EnsembleScaffold.ProfileToolbar.imageDimension
                )
                .clipShape(Circle())
        } else {
            Image(systemName: EnsembleDesign.Icon.profilePlaceholder)
                .font(EnsembleDesign.Typography.detailSubtitle)
        }
    }
}

// MARK: - Profile Toolbar Modifier

private struct ShowsProfileToolbarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsProfileToolbar: Bool {
        get { self[ShowsProfileToolbarKey.self] }
        set { self[ShowsProfileToolbarKey.self] = newValue }
    }
}

/// Adds the profile button on iPhone root tab views only.
/// iOS 15 uses `navigationBarItems` because stacked `.toolbar` modifiers
/// can drop trailing items in `NavigationView`.
struct ProfileToolbarModifier: ViewModifier {
    @Environment(\.showsProfileToolbar) private var showsProfileToolbar

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            content.toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showsProfileToolbar {
                        ProfileToolbarButton()
                    }
                }
            }
        } else {
            content.navigationBarItems(
                trailing: Group {
                    if showsProfileToolbar {
                        ProfileToolbarButton()
                    }
                }
            )
        }
        #else
        content
        #endif
    }
}

extension View {
    func profileToolbar() -> some View {
        modifier(ProfileToolbarModifier())
    }
}

/// Loads a small profile image for toolbar display using platform-native APIs
private struct LocalToolbarProfileImage: View {
    let url: URL
    let reloadToken: Date
    @State private var image: Image?

    var body: some View {
        Group {
            if let image = image {
                image
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: EnsembleDesign.Icon.profilePlaceholder)
                    .font(EnsembleDesign.Typography.detailSubtitle)
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _ in loadImage() }
        .onChange(of: reloadToken) { _ in loadImage() }
    }

    private func loadImage() {
        #if canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: url.path) {
            image = Image(uiImage: uiImage)
        } else {
            image = nil
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(contentsOf: url) {
            image = Image(nsImage: nsImage)
        } else {
            image = nil
        }
        #endif
    }
}
