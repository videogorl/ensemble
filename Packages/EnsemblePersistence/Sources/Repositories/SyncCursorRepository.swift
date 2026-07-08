import CoreData
import Foundation

public struct SyncCursorRecord: Equatable, Sendable {
    public let scopeKey: String
    public let scopeType: String
    public let lastIncrementalSyncAt: Date?
    public let lastInventorySyncAt: Date?
    public let lastFullSyncAt: Date?
    public let lastSuccessfulSyncAt: Date?
    public let updatedAt: Date?

    public init(
        scopeKey: String,
        scopeType: String,
        lastIncrementalSyncAt: Date? = nil,
        lastInventorySyncAt: Date? = nil,
        lastFullSyncAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.scopeKey = scopeKey
        self.scopeType = scopeType
        self.lastIncrementalSyncAt = lastIncrementalSyncAt
        self.lastInventorySyncAt = lastInventorySyncAt
        self.lastFullSyncAt = lastFullSyncAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.updatedAt = updatedAt
    }
}

public enum SyncCursorScopeType: String, Sendable {
    case serverPlaylists = "server-playlists"
}

public protocol SyncCursorRepositoryProtocol: Sendable {
    func fetchCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws -> SyncCursorRecord?
    func recordIncrementalSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws
    func recordInventorySync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws
    func recordFullSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws
    func deleteCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws
}

public final class SyncCursorRepository: SyncCursorRepositoryProtocol, @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    public init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    public func fetchCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws -> SyncCursorRecord? {
        try await coreDataStack.performViewContext { context in
            try Self.fetchCursor(scopeKey: scopeKey, scopeType: scopeType, in: context).map(Self.record(from:))
        }
    }

    public func recordIncrementalSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
        try await updateCursor(scopeKey: scopeKey, scopeType: scopeType, at: date) { cursor in
            cursor.lastIncrementalSyncAt = date
            cursor.lastSuccessfulSyncAt = date
        }
    }

    public func recordInventorySync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
        try await updateCursor(scopeKey: scopeKey, scopeType: scopeType, at: date) { cursor in
            cursor.lastInventorySyncAt = date
            cursor.lastSuccessfulSyncAt = date
        }
    }

    public func recordFullSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
        try await updateCursor(scopeKey: scopeKey, scopeType: scopeType, at: date) { cursor in
            cursor.lastFullSyncAt = date
            cursor.lastInventorySyncAt = date
            cursor.lastSuccessfulSyncAt = date
        }
    }

    public func deleteCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws {
        try await coreDataStack.performBackgroundContext { context in
            if let cursor = try Self.fetchCursor(scopeKey: scopeKey, scopeType: scopeType, in: context) {
                context.delete(cursor)
                try context.save()
            }
        }
    }

    private func updateCursor(
        scopeKey: String,
        scopeType: SyncCursorScopeType,
        at date: Date,
        update: @escaping (CDSyncCursor) -> Void
    ) async throws {
        try await coreDataStack.performBackgroundContext { context in
            let cursor = try Self.fetchOrCreateCursor(scopeKey: scopeKey, scopeType: scopeType, in: context)
            update(cursor)
            cursor.updatedAt = date
            try context.save()
        }
    }

    private static func fetchOrCreateCursor(
        scopeKey: String,
        scopeType: SyncCursorScopeType,
        in context: NSManagedObjectContext
    ) throws -> CDSyncCursor {
        if let cursor = try fetchCursor(scopeKey: scopeKey, scopeType: scopeType, in: context) {
            return cursor
        }

        let cursor = CDSyncCursor(context: context)
        cursor.scopeKey = scopeKey
        cursor.scopeType = scopeType.rawValue
        cursor.updatedAt = Date()
        return cursor
    }

    private static func fetchCursor(
        scopeKey: String,
        scopeType: SyncCursorScopeType,
        in context: NSManagedObjectContext
    ) throws -> CDSyncCursor? {
        let request = CDSyncCursor.fetchRequest()
        request.predicate = NSPredicate(
            format: "scopeKey == %@ AND scopeType == %@",
            scopeKey,
            scopeType.rawValue
        )
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private static func record(from cursor: CDSyncCursor) -> SyncCursorRecord {
        SyncCursorRecord(
            scopeKey: cursor.scopeKey,
            scopeType: cursor.scopeType,
            lastIncrementalSyncAt: cursor.lastIncrementalSyncAt,
            lastInventorySyncAt: cursor.lastInventorySyncAt,
            lastFullSyncAt: cursor.lastFullSyncAt,
            lastSuccessfulSyncAt: cursor.lastSuccessfulSyncAt,
            updatedAt: cursor.updatedAt
        )
    }
}
