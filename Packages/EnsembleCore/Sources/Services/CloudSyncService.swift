import CloudKit
import Foundation

/// Manages CloudKit synchronization for user profile data.
/// Uses the private database in the app's iCloud container.
/// Designed to be extensible for future sync of pins, sources, etc.
public actor CloudSyncService {
    // MARK: - CloudKit Configuration

    private let container: CKContainer
    private let database: CKDatabase

    /// CloudKit record type for user profile
    private static let profileRecordType = "UserProfile"

    /// Fixed record ID for the single user profile record
    private static let profileRecordID = CKRecord.ID(recordName: "currentUserProfile")

    /// Field keys for the profile record
    private enum ProfileField {
        static let displayName = "displayName"
        static let profileImage = "profileImage"
        static let lastModified = "lastModified"
    }

    // MARK: - State

    private var isSubscribed = false

    /// Called on the main actor when a remote profile change is received
    public var onRemoteProfileChanged: (@Sendable (UserProfile, Data?) async -> Void)?

    // MARK: - Initialization

    public init(containerIdentifier: String = "iCloud.com.videogorl.ensemble") {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
    }

    /// Set the remote change callback (actor-isolated setter)
    public func setRemoteChangeHandler(_ handler: @escaping @Sendable (UserProfile, Data?) async -> Void) {
        onRemoteProfileChanged = handler
    }

    // MARK: - Profile Sync

    /// Push the local profile to CloudKit
    public func pushProfile(_ profile: UserProfile, imageData: Data?) async {
        do {
            // Fetch existing record or create new one
            let record: CKRecord
            do {
                record = try await database.record(for: Self.profileRecordID)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: Self.profileRecordType, recordID: Self.profileRecordID)
            }

            // Update fields
            record[ProfileField.displayName] = profile.displayName as CKRecordValue?
            record[ProfileField.lastModified] = profile.lastModified as CKRecordValue

            // Handle image asset
            if let imageData = imageData {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("profile_upload_\(UUID().uuidString).jpg")
                try imageData.write(to: tempURL)
                record[ProfileField.profileImage] = CKAsset(fileURL: tempURL)
            } else if profile.profileImagePath == nil {
                record[ProfileField.profileImage] = nil
            }

            // Save with last-writer-wins policy
            let modifyOp = CKModifyRecordsOperation(recordsToSave: [record])
            modifyOp.savePolicy = .changedKeys
            modifyOp.qualityOfService = .utility

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                modifyOp.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(modifyOp)
            }

            EnsembleLogger.info("Profile pushed to CloudKit successfully")
        } catch {
            Self.logCloudKitError(error, context: "pushProfile")
        }
    }

    /// Pull the latest profile from CloudKit
    public func pullProfile() async -> (profile: UserProfile, imageData: Data?)? {
        do {
            let record = try await database.record(for: Self.profileRecordID)
            return parseProfileRecord(record)
        } catch let error as CKError where error.code == .unknownItem {
            // No profile record exists yet — this is normal for first launch
            EnsembleLogger.info("No CloudKit profile record found (first launch)")
            return nil
        } catch {
            Self.logCloudKitError(error, context: "pullProfile")
            return nil
        }
    }

    /// Subscribe to remote profile changes via silent push notifications
    public func subscribeToChanges() async {
        guard !isSubscribed else { return }

        do {
            let subscriptionID = "profile-changes"

            // Check if subscription already exists
            do {
                _ = try await database.subscription(for: subscriptionID)
                isSubscribed = true
                EnsembleLogger.info("CloudKit profile subscription already exists")
                return
            } catch {
                // Subscription doesn't exist — create it
            }

            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true // Silent push
            subscription.notificationInfo = notificationInfo

            try await database.save(subscription)
            isSubscribed = true
            EnsembleLogger.info("CloudKit profile subscription created")
        } catch {
            Self.logCloudKitError(error, context: "subscribeToChanges")
        }
    }

    /// Handle a CloudKit remote notification — fetches changes and calls the callback
    public func handleRemoteNotification() async {
        guard let result = await pullProfile() else { return }
        await onRemoteProfileChanged?(result.profile, result.imageData)
    }

    // MARK: - Helpers

    /// Parse a CKRecord into a UserProfile + optional image data
    private func parseProfileRecord(_ record: CKRecord) -> (profile: UserProfile, imageData: Data?) {
        let displayName = record[ProfileField.displayName] as? String
        let lastModified = (record[ProfileField.lastModified] as? Date) ?? record.modificationDate ?? Date()

        var imageData: Data?
        var imagePath: String?
        if let asset = record[ProfileField.profileImage] as? CKAsset,
           let fileURL = asset.fileURL {
            imageData = try? Data(contentsOf: fileURL)
            if imageData != nil {
                imagePath = "avatar.jpg"
            }
        }

        let profile = UserProfile(
            displayName: displayName,
            profileImagePath: imagePath,
            lastModified: lastModified
        )

        return (profile, imageData)
    }

    /// Log CloudKit errors with appropriate severity
    private static func logCloudKitError(_ error: Error, context: String) {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure:
                EnsembleLogger.info("CloudKit \(context): network unavailable (offline mode)")
            case .notAuthenticated:
                EnsembleLogger.info("CloudKit \(context): user not signed into iCloud")
            case .quotaExceeded:
                EnsembleLogger.error("CloudKit \(context): iCloud storage quota exceeded")
            case .requestRateLimited:
                let retryAfter = ckError.retryAfterSeconds ?? 30
                EnsembleLogger.info("CloudKit \(context): rate limited, retry after \(retryAfter)s")
            default:
                EnsembleLogger.error("CloudKit \(context) error: \(ckError.localizedDescription)")
            }
        } else {
            EnsembleLogger.error("CloudKit \(context) error: \(error.localizedDescription)")
        }
    }
}
