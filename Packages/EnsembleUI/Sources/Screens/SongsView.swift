import EnsembleCore
import SwiftUI
import Nuke

public struct SongsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var trackIndexMap: [String: Int] = [:]
    @State private var showFilterSheet = false

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
        .searchable(text: $libraryVM.tracksFilterOptions.searchText, prompt: "Filter songs")
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.tracks.isEmpty {
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
                if !libraryVM.tracks.isEmpty {
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
                        // Add Sort Menu for macOS here if needed
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
        #if canImport(UIKit)
        IndexedTrackList(
            groupedTracks: groupedTracks,
            sectionTitles: sectionIndexTitles,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            onTrackTap: { track in
                let globalIndex = trackIndexMap[track.id] ?? 0
                nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: globalIndex)
            }
        )
        .onChange(of: libraryVM.filteredTracks) { tracks in
            // Rebuild index map when tracks change
            trackIndexMap = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
        }
        .onAppear {
            // Build initial index map
            trackIndexMap = Dictionary(uniqueKeysWithValues: libraryVM.filteredTracks.enumerated().map { ($1.id, $0) })
        }
        #else
        List {
            ForEach(Array(libraryVM.filteredTracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(
                    track: track,
                    isPlaying: track.id == nowPlayingVM.currentTrack?.id
                ) {
                    nowPlayingVM.play(tracks: libraryVM.filteredTracks, startingAt: index)
                }
            }
        }
        #endif
    }
    
    private var groupedTracks: [(letter: String, tracks: [Track])] {
        let grouped = Dictionary(grouping: libraryVM.filteredTracks) { track in
            track.title.indexingLetter
        }
        
        // Sort keys with # at the top
        let sortedKeys = grouped.keys.sorted { left, right in
            if left == "#" { return true }
            if right == "#" { return false }
            return left < right
        }
        
        return sortedKeys.map { key in
            (letter: key, tracks: grouped[key] ?? [])
        }
    }
    
    private var sectionIndexTitles: [String] {
        groupedTracks.map { $0.letter }
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
        #if canImport(UIKit)
        .background(Color(.systemBackground).opacity(0.95))
        #else
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        #endif
    }
}

#if canImport(UIKit)
import UIKit

// MARK: - Indexed Track List with Native Scrollbar

struct IndexedTrackList: UIViewRepresentable {
    let groupedTracks: [(letter: String, tracks: [Track])]
    let sectionTitles: [String]
    let currentTrackId: String?
    let onTrackTap: (Track) -> Void
    
    @Environment(\.dependencies) private var dependencies
    
    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.sectionIndexColor = .label
        tableView.sectionIndexBackgroundColor = .clear
        tableView.register(TrackTableViewCell.self, forCellReuseIdentifier: "TrackCell")
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        tableView.backgroundColor = .systemBackground
        tableView.contentInset = .zero
        tableView.scrollIndicatorInsets = .zero
        return tableView
    }
    
    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.groupedTracks = groupedTracks
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.onTrackTap = onTrackTap
        context.coordinator.artworkLoader = dependencies.artworkLoader
        tableView.reloadData()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            groupedTracks: groupedTracks,
            sectionTitles: sectionTitles,
            currentTrackId: currentTrackId,
            onTrackTap: onTrackTap,
            artworkLoader: dependencies.artworkLoader
        )
    }
    
    class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource {
        var groupedTracks: [(letter: String, tracks: [Track])]
        let sectionTitles: [String]
        var currentTrackId: String?
        var onTrackTap: (Track) -> Void
        var artworkLoader: ArtworkLoaderProtocol
        
        init(groupedTracks: [(letter: String, tracks: [Track])], sectionTitles: [String], currentTrackId: String?, onTrackTap: @escaping (Track) -> Void, artworkLoader: ArtworkLoaderProtocol) {
            self.groupedTracks = groupedTracks
            self.sectionTitles = sectionTitles
            self.currentTrackId = currentTrackId
            self.onTrackTap = onTrackTap
            self.artworkLoader = artworkLoader
        }
        
        func numberOfSections(in tableView: UITableView) -> Int {
            groupedTracks.count
        }
        
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            groupedTracks[section].tracks.count
        }
        
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "TrackCell", for: indexPath) as! TrackTableViewCell
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            let isPlaying = track.id == currentTrackId
            cell.configure(
                with: track,
                showArtwork: true,
                showTrackNumber: false,
                isPlaying: isPlaying,
                artworkLoader: artworkLoader
            )
            return cell
        }
        
        func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            groupedTracks[section].letter
        }
        
        func sectionIndexTitles(for tableView: UITableView) -> [String]? {
            sectionTitles
        }
        
        func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
            index
        }
        
        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            onTrackTap(track)
        }
        
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            68
        }
    }
}
#endif



