import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct SongsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showFilterSheet = false
    @State private var selectedAlbum: Album?
    
    private var backgroundColor: Color {
        #if os(macOS)
        return Color(NSColor.windowBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            Group {
                if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                    loadingView
                } else if libraryVM.tracks.isEmpty {
                    emptyView
                } else if isLandscape {
                    albumCoverFlowView
                        .navigationBarHidden(true)
                        .statusBar(hidden: true)
                } else {
                    trackListView
                }
            }
            #if os(iOS)
            .preference(key: ChromeVisibilityPreferenceKey.self, value: isLandscape)
            #endif
            .navigationTitle(isLandscape ? "" : "Songs")
            .searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
            .refreshable {
                await libraryVM.refresh()
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !libraryVM.tracks.isEmpty && !isLandscape {
                        HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                
                                // Badge indicator when filters are active
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }

                        Menu {
                            Menu {
                                ForEach(TrackSortOption.allCases, id: \.self) { option in
                                    Button {
                                        libraryVM.trackSortOption = option
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if libraryVM.trackSortOption == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Sort By", systemImage: "arrow.up.arrow.down")
                            }
                            
                            Divider()
                            
                            Button {
                                nowPlayingVM.shufflePlay(tracks: libraryVM.filteredTracks)
                            } label: {
                                Label("Shuffle All", systemImage: "shuffle")
                            }

                            Button {
                                nowPlayingVM.play(tracks: libraryVM.filteredTracks)
                            } label: {
                                Label("Play All", systemImage: "play.fill")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    if !libraryVM.tracks.isEmpty && !isLandscape {
                    HStack(spacing: 16) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                if libraryVM.tracksFilterOptions.hasActiveFilters {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                    }
                }
            }
            #endif
            }
        .sheet(isPresented: $showFilterSheet) {
            FilterSheet(
                filterOptions: $libraryVM.tracksFilterOptions
            )
        }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading songs...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Songs")
                .font(.title2)

            Text("Tap the sync button to sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var trackListView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    if libraryVM.trackSortOption == .title {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(libraryVM.trackSections) { section in
                                Section(header: sectionHeader(section.letter)) {
                                    VStack(spacing: 0) {
                                        ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                                            TrackRow(
                                                track: track,
                                                showArtwork: true,
                                                isPlaying: track.id == nowPlayingVM.currentTrack?.id
                                            ) {
                                                // Find global index for the track
                                                if let globalIndex = libraryVM.filteredTracks.firstIndex(where: { $0.id == track.id }) {
                                                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
                                                }
                                            }
                                            .id(track.id)
                                            .padding(.horizontal)
                                            .padding(.vertical, 8)
                                            
                                            if index < section.tracks.count - 1 {
                                                Divider()
                                                    .padding(.leading, 68)
                                            }
                                        }
                                    }
                                }
                                .id(section.letter)
                            }
                        }
                        .padding(.vertical)
                    } else {
                        TrackListView(
                            tracks: libraryVM.filteredTracks,
                            showArtwork: true,
                            showTrackNumbers: false,
                            currentTrackId: nowPlayingVM.currentTrack?.id
                        ) { track, index in
                            nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
                        }
                        .padding(.vertical)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 140)
                }
                
                if libraryVM.trackSortOption == .title && !libraryVM.filteredTracks.isEmpty {
                    ScrollIndex(
                        letters: libraryVM.trackSections.map { $0.letter },
                        currentLetter: .constant(nil),
                        onLetterTap: { letter in
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    )
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.headline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(backgroundColor.opacity(0.9))
    }
    
    private var albumCoverFlowView: some View {
        CoverFlowView(
            items: libraryVM.albums,
            itemView: { album in
                CoverFlowItemView(album: album)
            },
            detailContent: { selectedAlbum in
                if let selectedAlbum = selectedAlbum {
                    AnyView(
                        CoverFlowDetailView(
                            contentType: .album(selectedAlbum.id),
                            nowPlayingVM: nowPlayingVM
                        )
                    )
                } else {
                    AnyView(Color.clear.frame(height: 0))
                }
            },
            selectedItem: $selectedAlbum
        )
        .background(Color.black)
    }
}