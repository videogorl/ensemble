import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

struct HiddenMediaView: View {
    let nowPlayingVM: NowPlayingViewModel
    @StateObject private var viewModel = DependencyContainer.shared.makeHiddenMediaViewModel()
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var expandedSections = Set<HiddenMediaKind>()
    @State private var isEditingOrder = false
    @State private var playlistActionRequest: PlaylistActionPresentationRequest?
    @State private var libraryItemInfoRequest: LibraryItemInfoRequest?

    private let columns = [
        GridItem(
            .adaptive(
                minimum: EnsembleScaffold.MediaCard.hubArtworkDimension,
                maximum: EnsembleScaffold.MediaCard.hubArtworkDimension
            ),
            spacing: EnsembleScaffold.MediaCard.gridSpacing,
            alignment: .top
        )
    ]

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("Loading Hidden")
            } else if viewModel.items.isEmpty {
                EnsembleStateScaffold(
                    kind: .empty,
                    title: "Nothing Hidden",
                    message: "Hide an item from its menu and it will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(viewModel.store.sectionOrder) { kind in
                            let items = viewModel.items(for: kind)
                            if !items.isEmpty {
                                section(kind, items: items)
                            }
                        }
                    }
                    .padding()
                }
                .restoringSceneScrollPosition(.hidden)
            }
        }
        .miniPlayerBottomSpacing()
        .navigationTitle("Hidden")
        .toolbar {
            ToolbarItem(placement: .primaryActionIfAvailable) {
                Button("Edit") { isEditingOrder = true }
            }
        }
        .sheet(isPresented: $isEditingOrder) {
            HiddenSectionOrderView(store: viewModel.store)
        }
        .playlistActionPresentation(request: $playlistActionRequest, nowPlayingVM: nowPlayingVM)
        .libraryItemInfoPresentation(request: $libraryItemInfoRequest)
        .onAppear { nowPlayingVM.beginHiddenPlaybackScope() }
        .onDisappear { nowPlayingVM.endHiddenPlaybackScope() }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func section(_ kind: HiddenMediaKind, items: [ResolvedHiddenMediaItem]) -> some View {
        let isExpandable = items.count > 4
        let displayed = isExpandable && !expandedSections.contains(kind) ? Array(items.prefix(4)) : items

        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard isExpandable else { return }
                if expandedSections.contains(kind) {
                    expandedSections.remove(kind)
                } else {
                    expandedSections.insert(kind)
                }
            } label: {
                HStack {
                    Text(kind.title).font(.title2.weight(.semibold))
                    Spacer()
                    if isExpandable {
                        Image(systemName: expandedSections.contains(kind) ? "chevron.up" : "chevron.down")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVGrid(columns: columns, spacing: EnsembleScaffold.MediaCard.rowSpacing) {
                ForEach(displayed) { item in
                    HubItemCard(
                        displayItem: DisplayHubItem(items: [item.hubItem]),
                        nowPlayingVM: nowPlayingVM,
                        navigationCoordinator: navigationCoordinator,
                        includesHidden: true,
                        playlistActionRequest: $playlistActionRequest,
                        libraryItemInfoRequest: $libraryItemInfoRequest
                    )
                }
            }
        }
    }
}

private extension ResolvedHiddenMediaItem {
    var hubItem: HubItem {
        switch self {
        case .playlist(let playlist):
            return HubItem(
                id: playlist.id,
                type: "playlist",
                title: playlist.title,
                subtitle: "\(playlist.trackCount) songs",
                thumbPath: playlist.compositePath ?? playlist.fallbackArtworkPath,
                year: nil,
                sourceCompositeKey: playlist.sourceCompositeKey ?? "",
                playlist: playlist
            )
        case .artist(let artist):
            return HubItem(
                id: artist.id,
                type: "artist",
                title: artist.name,
                subtitle: nil,
                thumbPath: artist.thumbPath ?? artist.fallbackThumbPath,
                year: nil,
                sourceCompositeKey: artist.sourceCompositeKey ?? "",
                artist: artist
            )
        case .album(let album):
            return HubItem(
                id: album.id,
                type: "album",
                title: album.title,
                subtitle: album.artistName,
                thumbPath: album.thumbPath,
                year: album.year,
                sourceCompositeKey: album.sourceCompositeKey ?? "",
                album: album
            )
        case .track(let track):
            return HubItem(
                id: track.id,
                type: "track",
                title: track.title,
                subtitle: track.artistName ?? track.albumName,
                thumbPath: track.thumbPath ?? track.fallbackThumbPath,
                year: nil,
                sourceCompositeKey: track.sourceCompositeKey ?? "",
                track: track
            )
        }
    }
}

private struct HiddenSectionOrderView: View {
    @ObservedObject var store: HiddenMediaStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            orderedList
            .navigationTitle("Edit Hidden")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var orderedList: some View {
        let list = List {
            ForEach(store.sectionOrder) { kind in
                Label(kind.title, systemImage: icon(for: kind))
            }
            .onMove(perform: store.moveSections)
        }
        #if os(iOS)
        list.environment(\.editMode, .constant(.active))
        #else
        list
        #endif
    }

    private func icon(for kind: HiddenMediaKind) -> String {
        switch kind {
        case .playlist: return EnsembleDesign.Icon.playlist
        case .artist: return EnsembleDesign.Icon.artist
        case .album: return EnsembleDesign.Icon.album
        case .track: return EnsembleDesign.Icon.musicNote
        }
    }
}
