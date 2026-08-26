import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Circular profile image + name header, modeled after Apple's iCloud Settings panel.
/// Tappable image opens photo picker; tappable name pushes to an edit view.
public struct ProfileHeaderView: View {
    @ObservedObject var profileStore: UserProfileStore
    @State private var showingImageSourcePicker = false
    @State private var showingImagePicker = false
    let onEditName: () -> Void

    public init(
        profileStore: UserProfileStore,
        onEditName: @escaping () -> Void = {}
    ) {
        self.profileStore = profileStore
        self.onEditName = onEditName
    }

    public var body: some View {
        VStack(spacing: EnsembleScaffold.ProfileHeader.contentSpacing) {
            Button {
                showingImageSourcePicker = true
            } label: {
                profileImageView
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change Profile Photo")
            .accessibilityHint("Choose or remove your profile photo")

            Button(action: onEditName) {
                nameView
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit your profile name")
        }
        .padding(.vertical, EnsembleScaffold.ProfileHeader.verticalPadding)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .confirmationDialog("Change Profile Photo", isPresented: $showingImageSourcePicker) {
            Button("Choose Photo…") {
                showingImagePicker = true
            }

            if profileStore.profile.profileImagePath != nil {
                Button("Remove Photo", role: .destructive) {
                    profileStore.clearProfileImage()
                }
            }
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePickerView { imageData in
                if let data = imageData {
                    profileStore.updateProfileImage(data)
                }
            }
        }
        #elseif os(macOS)
        .confirmationDialog("Change Profile Photo", isPresented: $showingImageSourcePicker) {
            Button("Choose Photo…") {
                showingImagePicker = true
            }

            if profileStore.profile.profileImagePath != nil {
                Button("Remove Photo", role: .destructive) {
                    profileStore.clearProfileImage()
                }
            }
        }
        .fileImporter(isPresented: $showingImagePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result,
               let data = try? Data(contentsOf: url) {
                profileStore.updateProfileImage(data)
            }
        }
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private var profileImageView: some View {
        if let imageURL = profileStore.profileImageURL {
            // Load local image from file URL
            LocalProfileImage(
                url: imageURL,
                reloadToken: profileStore.profile.lastModified
            ) {
                EnsembleDesign.Color.secondaryText.opacity(EnsembleScaffold.ProfileHeader.imageLoadingOpacity)
            }
                .frame(
                    width: EnsembleScaffold.ProfileHeader.imageDimension,
                    height: EnsembleScaffold.ProfileHeader.imageDimension
                )
                .clipShape(Circle())
        } else {
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        Image(systemName: EnsembleDesign.Icon.signIn)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(
                width: EnsembleScaffold.ProfileHeader.imageDimension,
                height: EnsembleScaffold.ProfileHeader.imageDimension
            )
            .foregroundColor(EnsembleDesign.Color.secondaryText.opacity(EnsembleScaffold.ProfileHeader.placeholderOpacity))
    }

    private var nameView: some View {
        VStack(spacing: EnsembleScaffold.ProfileHeader.nameSpacing) {
            if let name = profileStore.profile.displayName {
                Text(name)
                    .font(EnsembleDesign.Typography.profileName)
            } else {
                Text("Set Your Name")
                    .font(EnsembleDesign.Typography.profilePlaceholderName)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }
    }
}

// MARK: - UIImagePickerController Wrapper (iOS)

#if os(iOS)
import UIKit

struct ImagePickerView: UIViewControllerRepresentable {
    let onImagePicked: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (Data?) -> Void

        init(onImagePicked: @escaping (Data?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            let data = image?.jpegData(compressionQuality: 0.9)
            picker.dismiss(animated: true) { [weak self] in
                self?.onImagePicked(data)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
#endif
