import EnsembleCore
import SwiftUI

public struct SongsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var trackIndexMap: [String: Int] = [:]

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
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                let tracksByLetter = groupedTracks
                
                ForEach(tracksByLetter, id: \.letter) { group in
                    Section {
                        ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                isPlaying: track.id == nowPlayingVM.currentTrack?.id
                            ) {
                                // Use cached index map
                                let globalIndex = trackIndexMap[track.id] ?? 0
                                nowPlayingVM.play(tracks: libraryVM.tracks, startingAt: globalIndex)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            if index < group.tracks.count - 1 {
                                Divider()
                                    .padding(.leading, 68)
                            }
                        }
                    } header: {
                        SectionHeader(title: group.letter)
                    }
                }
            }
        }
        .onChange(of: libraryVM.tracks) { tracks in
            // Rebuild index map when tracks change
            trackIndexMap = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
        }
        .onAppear {
            // Build initial index map
            trackIndexMap = Dictionary(uniqueKeysWithValues: libraryVM.tracks.enumerated().map { ($1.id, $0) })
        }
    }
    
    private var groupedTracks: [(letter: String, tracks: [Track])] {
        let grouped = Dictionary(grouping: libraryVM.tracks) { track in
            String(track.title.prefix(1)).uppercased()
        }
        return grouped.keys.sorted().map { key in
            (letter: key, tracks: grouped[key] ?? [])
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
