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
            } else if viewModel.results.isEmpty {
                noResultsView
            } else {
                resultsView
            }
        }
        .navigationTitle("Search")
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
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        isPlaying: track.id == nowPlayingVM.currentTrack?.id
                    ) {
                        nowPlayingVM.play(tracks: viewModel.results, startingAt: index)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
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

                    if index < viewModel.results.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // When keyboard is visible, use keyboard height; otherwise use tab bar + mini player height
            Color.clear.frame(height: keyboardHeight > 0 ? keyboardHeight : 110)
        }
    }
}
