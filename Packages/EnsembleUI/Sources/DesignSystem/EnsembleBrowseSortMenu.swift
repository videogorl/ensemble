import EnsembleCore
import EnsembleDesignTokens
import SwiftUI

protocol EnsembleBrowseSortOption: CaseIterable, Hashable, RawRepresentable where RawValue == String {
    var defaultDirection: SortDirection { get }
}

extension TrackSortOption: EnsembleBrowseSortOption {}
extension AlbumSortOption: EnsembleBrowseSortOption {}
extension ArtistSortOption: EnsembleBrowseSortOption {}
extension PlaylistSortOption: EnsembleBrowseSortOption {}
extension FavoritesSortOption: EnsembleBrowseSortOption {}

struct EnsembleBrowseSortMenu<Option: EnsembleBrowseSortOption, Model: ObservableObject>: View {
    @ObservedObject var model: Model
    let options: [Option]
    let selection: (Model) -> Option
    let direction: (Model) -> SortDirection
    let select: (Option, SortDirection) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    let nextDirection = selection(model) == option
                        ? (direction(model) == .ascending ? .descending : .ascending)
                        : option.defaultDirection
                    select(option, nextDirection)
                } label: {
                    HStack {
                        Text(option.rawValue)
                        if selection(model) == option {
                            Image(systemName: direction(model) == .ascending
                                ? EnsembleDesign.Icon.chevronUp : EnsembleDesign.Icon.chevronDown)
                        }
                    }
                }
            }
        } label: {
            Label("Sort By", systemImage: EnsembleDesign.Icon.sort)
        }
    }
}
