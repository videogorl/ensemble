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
            guard let sourceKey = item.sourceCompositeKey,
                  MediaSourceIdentity.parse(sourceKey) != nil else {
                return false
            }
            if let sourceConfiguration,
               !sourceConfiguration.shouldPreserveSourceKey(sourceKey) {
                return false
            }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }
}
