import EnsembleCore
import SwiftUI

struct HiddenMediaView: View {
    let nowPlayingVM: NowPlayingViewModel
    @StateObject private var viewModel = DependencyContainer.shared.makeHiddenMediaViewModel()
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @State private var expandedSections = Set<HiddenMediaKind>()
    @State private var isEditingOrder = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)

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

            if kind == .track {
                VStack(spacing: 0) {
                    ForEach(displayed) { item in hiddenTrackRow(item) }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(displayed) { item in hiddenCard(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func hiddenCard(_ item: ResolvedHiddenMediaItem) -> some View {
        switch item {
        case .playlist(let playlist):
            navigationCoordinator.routeLink(
                to: .playlistDetail(playlist, includesHidden: true),
                in: .settings
            ) {
                card(title: playlist.title) { ArtworkView(playlist: playlist, size: .thumbnail) }
            }
            .buttonStyle(.plain)
            .contextMenu { PlaylistActionsContextMenu(playlist: playlist, nowPlayingVM: nowPlayingVM) }
        case .artist(let artist):
            navigationCoordinator.routeLink(
                to: .artistDetail(artist, includesHidden: true),
                in: .settings
            ) {
                card(title: artist.name) {
                    ArtworkView(
                        artist: artist,
                        size: .thumbnail,
                        cornerRadius: ArtworkCornerRadius.circle(for: ArtworkSize.thumbnail.cgSize.width)
                    )
                }
            }
            .buttonStyle(.plain)
            .contextMenu { ArtistActionsContextMenu(artist: artist, nowPlayingVM: nowPlayingVM) }
        case .album(let album):
            navigationCoordinator.routeLink(
                to: .albumDetail(album, includesHidden: true),
                in: .settings
            ) {
                card(title: album.title) { ArtworkView(album: album, size: .thumbnail) }
            }
            .buttonStyle(.plain)
            .contextMenu {
                AlbumActionsContextMenu(album: album, nowPlayingVM: nowPlayingVM)
            }
        case .track:
            EmptyView()
        }
    }

    @ViewBuilder
    private func hiddenTrackRow(_ item: ResolvedHiddenMediaItem) -> some View {
        if case .track(let track) = item {
            Button { nowPlayingVM.playHidden(track: track) } label: {
                HStack(spacing: 12) {
                    ArtworkView(
                        track: track,
                        size: .tiny,
                        cornerRadius: ArtworkCornerRadius.square(for: .tiny)
                    )
                    VStack(alignment: .leading) {
                        Text(track.title).lineLimit(1)
                        Text(track.artistName ?? track.albumName ?? "")
                            .font(.caption)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .contextMenu { TrackActionsContextMenu(track: track, nowPlayingVM: nowPlayingVM) }
        }
    }

    private func card<Artwork: View>(title: String, @ViewBuilder artwork: () -> Artwork) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork()
            Text(title).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
