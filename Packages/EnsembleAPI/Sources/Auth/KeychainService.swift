import Foundation
@preconcurrency import KeychainAccess

public protocol KeychainServiceProtocol: Sendable {
    func save(_ value: String, forKey key: String) throws
    func get(_ key: String) throws -> String?
    func delete(_ key: String) throws

    // iCloud Keychain sync (optional — default no-ops for test mocks)
    func saveSynchronizable(_ value: String, forKey key: String) throws
    func getSynchronizable(_ key: String) throws -> String?
    func deleteSynchronizable(_ key: String) throws
}

/// Default no-op implementations for sync methods (mocks don't need them)
public extension KeychainServiceProtocol {
    func saveSynchronizable(_ value: String, forKey key: String) throws {}
    func getSynchronizable(_ key: String) throws -> String? { nil }
    func deleteSynchronizable(_ key: String) throws {}
}

public final class KeychainService: KeychainServiceProtocol, Sendable {
    private let keychain: Keychain
    /// Synchronizable keychain for iCloud Keychain sync (account credentials)
    private let syncKeychain: Keychain

    public static let shared = KeychainService()

    public init(service: String = "com.ensemble.plex") {
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlock)
        // Use a separate service for sync to avoid attribute conflicts
        self.syncKeychain = Keychain(service: "\(service).sync")
            .accessibility(.afterFirstUnlock)
            .synchronizable(true)
    }

    public func save(_ value: String, forKey key: String) throws {
        try keychain.set(value, key: key)
    }

    public func get(_ key: String) throws -> String? {
        try keychain.get(key)
    }

    public func delete(_ key: String) throws {
        try keychain.remove(key)
    }

    /// Save a value to the synchronizable (iCloud Keychain) store
    public func saveSynchronizable(_ value: String, forKey key: String) throws {
        try syncKeychain.set(value, key: key)
    }

    /// Read a value from the synchronizable (iCloud Keychain) store
    public func getSynchronizable(_ key: String) throws -> String? {
        try syncKeychain.get(key)
    }

    /// Delete a value from the synchronizable (iCloud Keychain) store
    public func deleteSynchronizable(_ key: String) throws {
        try syncKeychain.remove(key)
    }
}

// MARK: - Keychain Keys

public enum KeychainKey {
    // Multi-account storage (JSON blob, local-only)
    public static let plexAccounts = "plex_accounts"

    // Syncable account credentials (JSON blob, iCloud Keychain)
    public static let plexAccountsSync = "plex_accounts_sync"

    // Shared client identifier
}
