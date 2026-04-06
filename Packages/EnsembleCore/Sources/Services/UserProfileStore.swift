import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Manages local persistence of the user profile (name + avatar image).
/// Profile data is stored as JSON + image file in App Support/Ensemble/Profile/.
@MainActor
public final class UserProfileStore: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var profile: UserProfile

    // MARK: - File Paths

    /// Base directory for profile data
    private let profileDirectory: URL

    /// Path to the JSON profile metadata file
    private var profileJSONURL: URL {
        profileDirectory.appendingPathComponent("profile.json")
    }

    /// Path to the avatar image file
    private var avatarImageURL: URL {
        profileDirectory.appendingPathComponent("avatar.jpg")
    }

    /// Maximum avatar dimension (width and height)
    private static let avatarMaxSize: CGFloat = 400

    /// JPEG compression quality for avatar
    private static let avatarCompressionQuality: CGFloat = 0.8

    // MARK: - Callbacks

    /// Called when the profile is updated locally (for CloudKit push)
    public var onProfileUpdated: ((UserProfile) -> Void)?

    // MARK: - Initialization

    public init() {
        // Set up profile directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        profileDirectory = appSupport.appendingPathComponent("Ensemble/Profile")

        // Load existing profile or create empty one
        profile = UserProfile()

        // Ensure directory exists and load profile
        createDirectoryIfNeeded()
        loadProfile()
    }

    // MARK: - Public API

    /// Update the user's display name
    public func updateName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (trimmed?.isEmpty == true) ? nil : trimmed
        guard profile.displayName != finalName else { return }

        profile.displayName = finalName
        profile.lastModified = Date()
        saveProfile()
        onProfileUpdated?(profile)
    }

    /// Update the profile image from raw image data.
    /// Resizes to 400×400 and compresses as JPEG.
    public func updateProfileImage(_ imageData: Data) {
        guard let resizedData = Self.processImageData(imageData) else { return }

        do {
            try resizedData.write(to: avatarImageURL)
            profile.profileImagePath = "avatar.jpg"
            profile.lastModified = Date()
            saveProfile()
            onProfileUpdated?(profile)
        } catch {
            EnsembleLogger.error("Failed to save profile image: \(error.localizedDescription)")
        }
    }

    /// Remove the profile image
    public func clearProfileImage() {
        guard profile.profileImagePath != nil else { return }

        try? FileManager.default.removeItem(at: avatarImageURL)
        profile.profileImagePath = nil
        profile.lastModified = Date()
        saveProfile()
        onProfileUpdated?(profile)
    }

    /// Get the full URL to the current profile image (if it exists)
    public var profileImageURL: URL? {
        guard profile.profileImagePath != nil else { return nil }
        let url = avatarImageURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Apply a profile received from CloudKit (does not trigger onProfileUpdated callback)
    public func applyRemoteProfile(_ remoteProfile: UserProfile, imageData: Data?) {
        // Apply if remote is newer, OR if local profile is empty (fresh install).
        // A fresh install sets lastModified = Date() which is newer than the remote,
        // so we must also check isEmpty to handle the first-sync case.
        guard profile.isEmpty || remoteProfile.lastModified > profile.lastModified else {
            EnsembleLogger.info("Skipping remote profile (local is newer or equal)")
            return
        }

        EnsembleLogger.info("Applying remote profile (name: \(remoteProfile.displayName ?? "nil"), hasImage: \(imageData != nil))")

        profile.displayName = remoteProfile.displayName
        profile.lastModified = remoteProfile.lastModified

        // Update image if provided
        if let imageData = imageData {
            if let processed = Self.processImageData(imageData) {
                try? processed.write(to: avatarImageURL)
                profile.profileImagePath = "avatar.jpg"
            }
        } else if remoteProfile.profileImagePath == nil {
            // Remote has no image — clear local
            try? FileManager.default.removeItem(at: avatarImageURL)
            profile.profileImagePath = nil
        }

        saveProfile()
    }

    /// Get raw image data for the current profile image (for CloudKit upload)
    public func getProfileImageData() -> Data? {
        guard profile.profileImagePath != nil else { return nil }
        return try? Data(contentsOf: avatarImageURL)
    }

    // MARK: - Private Helpers

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    }

    private func loadProfile() {
        guard FileManager.default.fileExists(atPath: profileJSONURL.path) else { return }

        do {
            let data = try Data(contentsOf: profileJSONURL)
            profile = try JSONDecoder().decode(UserProfile.self, from: data)
        } catch {
            EnsembleLogger.error("Failed to load profile: \(error.localizedDescription)")
        }
    }

    private func saveProfile() {
        do {
            let data = try JSONEncoder().encode(profile)
            try data.write(to: profileJSONURL)
        } catch {
            EnsembleLogger.error("Failed to save profile: \(error.localizedDescription)")
        }
    }

    /// Resize and compress image data to a square JPEG thumbnail
    private static func processImageData(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: avatarMaxSize, height: avatarMaxSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: avatarCompressionQuality)
        #elseif canImport(AppKit)
        guard let nsImage = NSImage(data: data) else { return nil }
        let size = NSSize(width: avatarMaxSize, height: avatarMaxSize)
        let resized = NSImage(size: size)
        resized.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: size),
                     from: NSRect(origin: .zero, size: nsImage.size),
                     operation: .copy,
                     fraction: 1.0)
        resized.unlockFocus()
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: avatarCompressionQuality])
        #else
        return nil
        #endif
    }
}
