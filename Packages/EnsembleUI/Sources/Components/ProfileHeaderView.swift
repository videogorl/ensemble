import EnsembleCore
import SwiftUI

/// Circular profile image + name header, modeled after Apple's iCloud Settings panel.
/// Tappable image opens photo picker; tappable name pushes to an edit view.
public struct ProfileHeaderView: View {
    @ObservedObject var profileStore: UserProfileStore
    @State private var showingImageSourcePicker = false
    @State private var showingNameEditor = false
    @State private var showingImagePicker = false

    public init(profileStore: UserProfileStore) {
        self.profileStore = profileStore
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Profile image — tappable to change
            profileImageView
                .onTapGesture {
                    showingImageSourcePicker = true
                }

            // Name + edit affordance — pushes to TextInputView
            nameView
                .onTapGesture {
                    showingNameEditor = true
                }

            // Hidden NavigationLink driven by showingNameEditor state.
            // Pushing replaces the root nav bar (which has scroll pocket tracking)
            // with an inline-title bar, so the keyboard won't trigger the iOS 26
            // ScrollPocketCollectorModel feedback loop.
            NavigationLink(isActive: $showingNameEditor) {
                TextInputView(
                    title: "Edit Name",
                    placeholder: "Your Name",
                    initialText: profileStore.profile.displayName ?? "",
                    actionTitle: "Save",
                    onSubmit: { newName in
                        profileStore.updateName(newName)
                    }
                )
            } label: {
                EmptyView()
            }
            .hidden()
            .frame(width: 0, height: 0)
        }
        .padding(.vertical, 24)
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
            LocalProfileImage(url: imageURL)
                .frame(width: 120, height: 120)
                .clipShape(Circle())
        } else {
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 120)
            .foregroundColor(.secondary.opacity(0.5))
    }

    private var nameView: some View {
        VStack(spacing: 4) {
            if let name = profileStore.profile.displayName {
                Text(name)
                    .font(.title2.bold())
            } else {
                Text("Set Your Name")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Local Profile Image Loader

/// Loads a profile image from a local file URL using platform-native APIs
private struct LocalProfileImage: View {
    let url: URL
    @State private var image: Image?

    var body: some View {
        Group {
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2)
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
