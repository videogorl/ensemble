import Foundation

// MARK: - Sort Options

public enum SortDirection: String, Codable, CaseIterable {
    case ascending
    case descending
    
    public var label: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

// MARK: - Filter Options

/// Filtering and sorting options for list views
public struct FilterOptions: Codable, Equatable {
    // Search/Filter text
    public var searchText: String = ""
    
    // Sort configuration
    public var sortBy: String = "default"  // View-specific sort key
    public var sortDirection: SortDirection = .ascending
    
    // Genre filtering
    public var selectedGenres: Set<String> = []
    
    // Artist filtering (for albums/songs)
    public var selectedArtists: Set<String> = []
    
    // Year range filtering (for albums)
    public var yearRange: ClosedRange<Int>? = nil
    
    // Downloaded content only
    public var showDownloadedOnly: Bool = false
    
    public init() {}
    
    /// Check if any filters are active (excluding search text)
    public var hasActiveFilters: Bool {
        !selectedGenres.isEmpty ||
        !selectedArtists.isEmpty ||
        yearRange != nil ||
        showDownloadedOnly
    }
    
    /// Clear all filters but keep search text
    public mutating func clearFilters() {
        selectedGenres.removeAll()
        selectedArtists.removeAll()
        yearRange = nil
        showDownloadedOnly = false
    }
    
    /// Reset to default state
    public mutating func reset() {
        searchText = ""
        sortBy = "default"
        sortDirection = .ascending
        clearFilters()
    }
}

// MARK: - Filter Persistence

/// Manages saving and loading filter options to UserDefaults
public final class FilterPersistence {
    private static let keyPrefix = "Ensemble.FilterOptions."
    
    /// Save filter options for a specific view type
    public static func save(_ options: FilterOptions, for viewType: String) {
        let key = keyPrefix + viewType
        if let encoded = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
    
    /// Load filter options for a specific view type
    public static func load(for viewType: String) -> FilterOptions {
        let key = keyPrefix + viewType
        guard let data = UserDefaults.standard.data(forKey: key),
              let options = try? JSONDecoder().decode(FilterOptions.self, from: data) else {
            return FilterOptions()
        }
        return options
    }
    
    /// Clear saved filters for a specific view type
    public static func clear(for viewType: String) {
        let key = keyPrefix + viewType
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    /// Clear all saved filters
    public static func clearAll() {
        let viewTypes = ["Albums", "Artists", "Songs", "Playlists", "Genres", "AlbumDetail", "ArtistDetail"]
        viewTypes.forEach { clear(for: $0) }
    }
}
