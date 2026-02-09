import Combine
import Foundation
import SwiftUI

// MARK: - Pinned Item Types

/// Types of content that can be pinned for quick access
public enum PinnedItemType: String, Codable, Sendable {
    case album, artist, playlist
}

/// Lightweight reference to a pinned item, stored in UserDefaults
public struct PinnedItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String              // ratingKey
    public let sourceCompositeKey: String
    public let type: PinnedItemType
    public let title: String           // Display name for sidebar
    public let pinnedDate: Date

    public init(id: String, sourceCompositeKey: String, type: PinnedItemType, title: String, pinnedDate: Date = Date()) {
        self.id = id
        self.sourceCompositeKey = sourceCompositeKey
        self.type = type
        self.title = title
        self.pinnedDate = pinnedDate
    }
}

// MARK: - Pin Manager

/// Manages pinned items, persisted to UserDefaults as JSON
@MainActor
public final class PinManager: ObservableObject {
    @AppStorage("pinnedItems") private var pinnedItemsData: Data = Data()

    @Published public private(set) var pinnedItems: [PinnedItem] = []

    public init() {
        loadPins()
    }

    // MARK: - Public API

    /// Pin an item for quick access
    public func pin(id: String, sourceKey: String, type: PinnedItemType, title: String) {
        guard !isPinned(id: id) else { return }
        let item = PinnedItem(id: id, sourceCompositeKey: sourceKey, type: type, title: title)
        pinnedItems.append(item)
        savePins()
    }

    /// Remove a pinned item
    public func unpin(id: String) {
        pinnedItems.removeAll { $0.id == id }
        savePins()
    }

    /// Check if an item is currently pinned
    public func isPinned(id: String) -> Bool {
        pinnedItems.contains { $0.id == id }
    }

    // MARK: - Persistence

    private func loadPins() {
        guard !pinnedItemsData.isEmpty,
              let decoded = try? JSONDecoder().decode([PinnedItem].self, from: pinnedItemsData) else {
            return
        }
        pinnedItems = decoded
    }

    private func savePins() {
        if let encoded = try? JSONEncoder().encode(pinnedItems) {
            pinnedItemsData = encoded
        }
        objectWillChange.send()
    }
}
