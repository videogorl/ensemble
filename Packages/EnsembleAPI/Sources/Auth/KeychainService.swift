import Foundation
import KeychainAccess

public protocol KeychainServiceProtocol: Sendable {
    func save(_ value: String, forKey key: String) throws
    func get(_ key: String) throws -> String?
    func delete(_ key: String) throws
}

public final class KeychainService: KeychainServiceProtocol, Sendable {
    private let keychain: Keychain

    public static let shared = KeychainService()

    public init(service: String = "com.ensemble.plex") {
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlock)
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
}

// MARK: - Keychain Keys

public enum KeychainKey {
    // Multi-account storage (JSON blob)
    public static let plexAccounts = "plex_accounts"

    // Shared client identifier
    public static let plexClientIdentifier = "plex_client_identifier"
}
