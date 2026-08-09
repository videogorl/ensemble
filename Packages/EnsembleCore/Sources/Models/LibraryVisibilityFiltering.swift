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
        var visibilityBySourceKey: [String: Bool] = [:]
        return items.filter { item in
            guard let sourceKey = item.sourceCompositeKey else { return false }
            if let isVisible = visibilityBySourceKey[sourceKey] {
                return isVisible
            }

            let isVisible: Bool
            if MediaSourceIdentity.parse(sourceKey) == nil {
                isVisible = false
            } else if let sourceConfiguration,
                      !sourceConfiguration.shouldPreserveSourceKey(sourceKey) {
                isVisible = false
            } else {
                isVisible = !isHiddenSourceKey(
                    sourceKey,
                    hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
                    sourceConfiguration: sourceConfiguration
                )
            }
            visibilityBySourceKey[sourceKey] = isVisible
            return isVisible
        }
    }

    static func isHiddenSourceKey(
        _ sourceKey: String,
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot?
    ) -> Bool {
        if hiddenSourceCompositeKeys.contains(sourceKey) { return true }
        guard let sourceConfiguration,
              let identity = MediaSourceIdentity.parse(sourceKey),
              identity.isServerScoped,
              identity.sourceType.capabilities.playlistsAreServerScoped else {
            return false
        }

        let enabledLibraries = sourceConfiguration.enabledSources.filter {
            $0.type == identity.sourceType &&
                $0.accountId == identity.accountId &&
                $0.serverId == identity.serverId
        }
        return !enabledLibraries.isEmpty && enabledLibraries.allSatisfy {
            hiddenSourceCompositeKeys.contains($0.compositeKey)
        }
    }
}
