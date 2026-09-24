@testable import EnsembleAPI

final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private var syncStorage: [String: String] = [:]

    func save(_ value: String, forKey key: String) throws {
        storage[key] = value
    }

    func get(_ key: String) throws -> String? {
        storage[key]
    }

    func delete(_ key: String) throws {
        storage.removeValue(forKey: key)
    }

    func saveSynchronizable(_ value: String, forKey key: String) throws {
        syncStorage[key] = value
    }

    func getSynchronizable(_ key: String) throws -> String? {
        syncStorage[key]
    }

    func deleteSynchronizable(_ key: String) throws {
        syncStorage.removeValue(forKey: key)
    }
}
