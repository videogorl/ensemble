import EnsembleCore
import SwiftUI

public struct SongsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.tracks.isEmpty {
                loadingView
            } else if libraryVM.tracks.isEmpty {
                emptyView
            } else {
                trackListView
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.tracks.isEmpty {
                    Menu {
                        Button {
                            nowPlayingVM.play(tracks: libraryVM.tracks.shuffled())
                        } label: {
                            Label("Shuffle All", systemImage: "shuffle")
                        }

                        Button {
                            nowPlayingVM.play(tracks: libraryVM.tracks)
                        } label: {
                            Label("Play All", systemImage: "play.fill")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .refreshable {
            await libraryVM.syncLibrary()
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

            Text("Pull to refresh or sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Sync Library") {
                Task {
                    await libraryVM.syncLibrary()
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var trackListView: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Group by first letter
                let grouped = Dictionary(grouping: libraryVM.tracks) { track in
                    String(track.title.prefix(1)).uppercased()
                }
                let sortedKeys = grouped.keys.sorted()

                ForEach(sortedKeys, id: \.self) { key in
                    Section {
                        if let tracks = grouped[key] {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(
                                    track: track,
                                    isPlaying: track.id == nowPlayingVM.currentTrack?.id
                                ) {
                                    nowPlayingVM.play(tracks: libraryVM.tracks, startingAt: libraryVM.tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)

                                if index < tracks.count - 1 {
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                        }
                    } header: {
                        SectionHeader(title: key)
                    }
                }
            }
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.95))
    }
}
