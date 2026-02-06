import EnsembleCore
import SwiftUI
import Combine

public struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @State private var keyboardHeight: CGFloat = 0

    public init(nowPlayingVM: NowPlayingViewModel, viewModel: SearchViewModel? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel ?? DependencyContainer.shared.makeSearchViewModel())
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar

            // Content
            if viewModel.searchQuery.isEmpty {
                emptySearchView
            } else if viewModel.isSearching {
                loadingView
            } else if viewModel.trackResults.isEmpty && viewModel.artistResults.isEmpty && viewModel.albumResults.isEmpty {
                noResultsView
            } else {
                resultsView
            }
        }
        .navigationTitle("Search")
        .safeAreaInset(edge: .bottom) {
            // When keyboard is visible, don't add extra padding (keyboard manages its own space)
            // Otherwise add padding for tab bar + mini player
            Color.clear.frame(height: keyboardHeight > 0 ? 0 : 110)
        }
        .onReceive(viewModel.focusRequested) {
            isSearchFieldFocused = true
        }
        #if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardHeight = keyboardFrame.height
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = 0
            }
        }
        #endif
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Songs, artists, albums", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
                .focused($isSearchFieldFocused)

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .padding()
    }

    private var emptySearchView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Search your music library")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text("Searching...")
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.title2)

            Text("Try a different search term")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
    }

    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Artists
                if !viewModel.artistResults.isEmpty {
                    searchSection(title: "Artists") {
                        ForEach(viewModel.artistResults) { artist in
                            if #available(iOS 16.0, *) {
                                NavigationLink(value: NavigationCoordinator.Destination.artist(id: artist.id)) {
                                    ArtistRow(artist: artist)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    ArtistDetailLoader(artistId: artist.id, nowPlayingVM: nowPlayingVM)
                                } label: {
                                    ArtistRow(artist: artist)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            if artist.id != viewModel.artistResults.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }
                
                // Albums
                if !viewModel.albumResults.isEmpty {
                    searchSection(title: "Albums") {
                        ForEach(viewModel.albumResults) { album in
                            if #available(iOS 16.0, *) {
                                NavigationLink(value: NavigationCoordinator.Destination.album(id: album.id)) {
                                    albumRow(album)
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    AlbumDetailLoader(albumId: album.id, nowPlayingVM: nowPlayingVM)
                                } label: {
                                    albumRow(album)
                                }
                                .buttonStyle(.plain)
                            }
                            
                            if album.id != viewModel.albumResults.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }
                
                // Songs
                if !viewModel.trackResults.isEmpty {
                    searchSection(title: "Songs") {
                        ForEach(Array(viewModel.trackResults.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                isPlaying: track.id == nowPlayingVM.currentTrack?.id
                            ) {
                                nowPlayingVM.play(tracks: viewModel.trackResults, startingAt: index)
                            }
                            .contextMenu {
                                Button {
                                    nowPlayingVM.playNext(track)
                                } label: {
                                    Label("Play Next", systemImage: "text.insert")
                                }

                                Button {
                                    nowPlayingVM.addToQueue(track)
                                } label: {
                                    Label("Add to Queue", systemImage: "text.badge.plus")
                                }
                            }

                            if index < viewModel.trackResults.count - 1 {
                                Divider()
                                    .padding(.leading, 68)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }
    
    private func searchSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal)
        }
    }
    
    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            ArtworkView(album: album, size: .tiny, cornerRadius: 4)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                Text(album.artistName ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}