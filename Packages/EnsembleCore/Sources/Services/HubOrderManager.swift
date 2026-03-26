import Foundation

/// Manages hub section ordering per music source (account/server/library)
/// Persists custom order to UserDefaults and applies it to fetched hubs
public final class HubOrderManager {
    private let userDefaults: UserDefaults
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
    
    /// Generate a unique key for storing order per source
    private func orderKey(for sourceKey: String) -> String {
        "hub_order_\(sourceKey)"
    }

    private func defaultOrderKey(for sourceKey: String) -> String {
        "hub_default_order_\(sourceKey)"
    }
    
    /// Save the current hub order for a specific source
    public func saveOrder(_ hubIds: [String], for sourceKey: String) {
        let key = orderKey(for: sourceKey)
        EnsembleLogger.debug("[HubOrder] Save order key=\(key) count=\(hubIds.count)")
        userDefaults.set(hubIds, forKey: key)
    }

    /// Save the default (server) order for a specific source
    public func saveDefaultOrder(_ hubIds: [String], for sourceKey: String) {
        let key = defaultOrderKey(for: sourceKey)
        EnsembleLogger.debug("[HubOrder] Save default order key=\(key) count=\(hubIds.count)")
        userDefaults.set(hubIds, forKey: key)
    }
    
    /// Load the saved order for a specific source
    public func loadOrder(for sourceKey: String) -> [String]? {
        let key = orderKey(for: sourceKey)
        let order = userDefaults.array(forKey: key) as? [String]
        EnsembleLogger.debug("[HubOrder] Load order key=\(key) count=\(order?.count ?? 0)")
        return order
    }

    private func loadDefaultOrder(for sourceKey: String) -> [String]? {
        let key = defaultOrderKey(for: sourceKey)
        let order = userDefaults.array(forKey: key) as? [String]
        EnsembleLogger.debug("[HubOrder] Load default order key=\(key) count=\(order?.count ?? 0)")
        return order
    }
    
    /// Apply saved order to fetched hubs
    /// - Returns: Hubs reordered according to saved order, with any new hubs appended at the end
    public func applyOrder(to hubs: [Hub], for sourceKey: String) -> [Hub] {
        guard let savedOrder = loadOrder(for: sourceKey) else {
            // No saved order, return hubs as-is
            return hubs
        }

        EnsembleLogger.debug("[HubOrder] Apply order sourceKey=\(sourceKey) hubs=\(hubs.count)")
        
        // Create a map of hub IDs to hubs for quick lookup.
        // Use uniquingKeysWith to safely handle any duplicate IDs that may have
        // entered the cache via a concurrent-save race in HubRepository.saveHubs.
        let hubMap = Dictionary(hubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var reorderedHubs: [Hub] = []
        var processedIds = Set<String>()
        
        // Add hubs in the saved order (which may no longer exist)
        for savedId in savedOrder {
            if let hub = hubMap[savedId] {
                reorderedHubs.append(hub)
                processedIds.insert(savedId)
            }
        }
        
        // Append any new hubs that weren't in the saved order
        for hub in hubs {
            if !processedIds.contains(hub.id) {
                reorderedHubs.append(hub)
            }
        }
        
        return reorderedHubs
    }

    /// Apply the default (server) order to the current hubs
    /// - Returns: Hubs reordered according to the stored default order
    public func applyDefaultOrder(to hubs: [Hub], for sourceKey: String) -> [Hub] {
        guard let defaultOrder = loadDefaultOrder(for: sourceKey) else {
            return hubs
        }

        EnsembleLogger.debug("[HubOrder] Apply default order sourceKey=\(sourceKey) hubs=\(hubs.count)")

        let hubMap = Dictionary(hubs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reorderedHubs: [Hub] = []
        var processedIds = Set<String>()

        for savedId in defaultOrder {
            if let hub = hubMap[savedId] {
                reorderedHubs.append(hub)
                processedIds.insert(savedId)
            }
        }

        for hub in hubs {
            if !processedIds.contains(hub.id) {
                reorderedHubs.append(hub)
            }
        }

        return reorderedHubs
    }
    
    /// Remap saved hub IDs using a pre-built mapping, then re-save.
    /// Used when hub IDs change format (single <-> merged) after library changes.
    public func migrateOrder(remapping: [String: String], for sourceKey: String) {
        guard let savedOrder = loadOrder(for: sourceKey) else { return }

        let hasStaleIds = savedOrder.contains { remapping[$0] != nil }
        guard hasStaleIds else { return }

        var remapped: [String] = []
        var seen = Set<String>()

        for savedId in savedOrder {
            let currentId = remapping[savedId] ?? savedId
            if seen.insert(currentId).inserted {
                remapped.append(currentId)
            }
        }

        EnsembleLogger.debug("[HubOrder] Migrated order for \(sourceKey): \(savedOrder.count) saved -> \(remapped.count) remapped")

        saveOrder(remapped, for: sourceKey)
    }

    /// Reset the saved order for a specific source
    public func resetOrder(for sourceKey: String) {
        let key = orderKey(for: sourceKey)
        EnsembleLogger.debug("[HubOrder] Reset order key=\(key)")
        userDefaults.removeObject(forKey: key)
    }
}
