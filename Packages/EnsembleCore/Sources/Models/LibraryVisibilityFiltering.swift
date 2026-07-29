import Foundation

protocol LibraryVisibilitySourceIdentifiable {
    var sourceCompositeKey: String? { get }
}

extension Track: LibraryVisibilitySourceIdentifiable {}
extension Artist: LibraryVisibilitySourceIdentifiable {}
extension Album: LibraryVisibilitySourceIdentifiable {}
extension Genre: LibraryVisibilitySourceIdentifiable {}
extension Playlist: LibraryVisibilitySourceIdentifiable {}

enum LibraryVisibilityFiltering {
    static func visibleItems<Item: LibraryVisibilitySourceIdentifiable>(
        _ items: [Item],
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot? = nil
    ) -> [Item] {
        return items.filter { item in
            if let sourceConfiguration,
               !sourceConfiguration.shouldPreserveSourceKey(item.sourceCompositeKey) {
                return false
            }
            guard let sourceKey = item.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }
}
