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
    public static let plexAuthToken = "plex_auth_token"
    public static let plexClientIdentifier = "plex_client_identifier"
    public static let selectedServerIdentifier = "selected_server_identifier"
    public static let selectedServerToken = "selected_server_token"
    public static let selectedServerURL = "selected_server_url"
    public static let selectedLibraryKey = "selected_library_key"
    public static let selectedLibraryTitle = "selected_library_title"
}
