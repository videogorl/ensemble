import Foundation

protocol LibraryVisibilitySourceIdentifiable {
    var sourceCompositeKey: String? { get }
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool
}

extension Track: LibraryVisibilitySourceIdentifiable {
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool { snapshot.isHidden(self) }
}
extension Artist: LibraryVisibilitySourceIdentifiable {
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool { snapshot.isHidden(self) }
}
extension Album: LibraryVisibilitySourceIdentifiable {
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool { snapshot.isHidden(self) }
}
extension Genre: LibraryVisibilitySourceIdentifiable {
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool { false }
}
extension Playlist: LibraryVisibilitySourceIdentifiable {
    func isHidden(in snapshot: HiddenMediaSnapshot) -> Bool { snapshot.isHidden(self) }
}

enum LibraryVisibilityFiltering {
    static func visibleItems<Item: LibraryVisibilitySourceIdentifiable>(
        _ items: [Item],
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot? = nil,
        hiddenMedia: HiddenMediaSnapshot = .empty
    ) -> [Item] {
        var visibilityBySourceKey: [String: Bool] = [:]
        return items.filter { item in
            guard !item.isHidden(in: hiddenMedia) else { return false }
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
