import EnsembleCore
import SwiftUI

public struct SongsView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var trackIndexMap: [String: Int] = [:]
    @State private var searchText = ""
    @State private var isSearchVisible = false

    public init(libraryVM: LibraryViewModel, nowPlayingVM: NowPlayingViewModel) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }
    
    private var filteredTracks: [Track] {
        let sorted = libraryVM.sortedTracks
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { track in
            track.title.localizedCaseInsensitiveContains(searchText) ||
            track.artistName?.localizedCaseInsensitiveContains(searchText) == true ||
            track.albumName?.localizedCaseInsensitiveContains(searchText) == true
        }
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .refreshable {
            await libraryVM.refresh()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !libraryVM.tracks.isEmpty {
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
                            nowPlayingVM.play(tracks: filteredTracks.shuffled())
                        } label: {
                            Label("Shuffle All", systemImage: "shuffle")
                        }

                        Button {
                            nowPlayingVM.play(tracks: filteredTracks)
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
        IndexedTrackList(
            groupedTracks: groupedTracks,
            sectionTitles: sectionIndexTitles,
            currentTrackId: nowPlayingVM.currentTrack?.id,
            onTrackTap: { track in
                let globalIndex = trackIndexMap[track.id] ?? 0
                nowPlayingVM.play(tracks: filteredTracks, startingAt: globalIndex)
            }
        )
        .onChange(of: filteredTracks) { tracks in
            // Rebuild index map when tracks change
            trackIndexMap = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.id, $0) })
        }
        .onAppear {
            // Build initial index map
            trackIndexMap = Dictionary(uniqueKeysWithValues: filteredTracks.enumerated().map { ($1.id, $0) })
        }
    }
    
    private var groupedTracks: [(letter: String, tracks: [Track])] {
        let grouped = Dictionary(grouping: filteredTracks) { track in
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
        .background(Color(.systemBackground).opacity(0.95))
    }
}
// MARK: - Indexed Track List with Native Scrollbar

struct IndexedTrackList: UIViewRepresentable {
    let groupedTracks: [(letter: String, tracks: [Track])]
    let sectionTitles: [String]
    let currentTrackId: String?
    let onTrackTap: (Track) -> Void
    
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
        return tableView
    }
    
    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.groupedTracks = groupedTracks
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.onTrackTap = onTrackTap
        tableView.reloadData()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(groupedTracks: groupedTracks, sectionTitles: sectionTitles, currentTrackId: currentTrackId, onTrackTap: onTrackTap)
    }
    
    class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource {
        var groupedTracks: [(letter: String, tracks: [Track])]
        let sectionTitles: [String]
        var currentTrackId: String?
        var onTrackTap: (Track) -> Void
        
        init(groupedTracks: [(letter: String, tracks: [Track])], sectionTitles: [String], currentTrackId: String?, onTrackTap: @escaping (Track) -> Void) {
            self.groupedTracks = groupedTracks
            self.sectionTitles = sectionTitles
            self.currentTrackId = currentTrackId
            self.onTrackTap = onTrackTap
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
            cell.configure(with: track, isPlaying: isPlaying)
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

class TrackTableViewCell: UITableViewCell {
    private var artworkHostingController: UIHostingController<ArtworkView>?
    private let artworkContainer = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingIndicator = UIImageView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artworkContainer)
        
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)
        
        durationLabel.font = .systemFont(ofSize: 14, weight: .regular)
        durationLabel.textColor = .secondaryLabel
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)
        
        playingIndicator.image = UIImage(systemName: "speaker.wave.3.fill")
        playingIndicator.tintColor = .systemBlue
        playingIndicator.contentMode = .scaleAspectFit
        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.isHidden = true
        contentView.addSubview(playingIndicator)
        
        NSLayoutConstraint.activate([
            artworkContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artworkContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkContainer.widthAnchor.constraint(equalToConstant: 44),
            artworkContainer.heightAnchor.constraint(equalToConstant: 44),
            
            titleLabel.leadingAnchor.constraint(equalTo: artworkContainer.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            
            subtitleLabel.leadingAnchor.constraint(equalTo: artworkContainer.trailingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            
            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            
            playingIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: 20),
            playingIndicator.heightAnchor.constraint(equalToConstant: 20)
        ])
    }
    
    func configure(with track: Track, isPlaying: Bool) {
        titleLabel.text = track.title
        
        var subtitleParts: [String] = []
        if let artist = track.artistName {
            subtitleParts.append(artist)
        }
        if let album = track.albumName {
            subtitleParts.append(album)
        }
        subtitleLabel.text = subtitleParts.joined(separator: " · ")
        
        durationLabel.text = track.formattedDuration
        durationLabel.isHidden = isPlaying
        playingIndicator.isHidden = !isPlaying
        
        // Setup SwiftUI artwork view
        let artworkView = ArtworkView(track: track, size: .thumbnail, cornerRadius: 4)
        
        if let hostingController = artworkHostingController {
            hostingController.rootView = artworkView
        } else {
            let hostingController = UIHostingController(rootView: artworkView)
            hostingController.view.backgroundColor = .clear
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            artworkContainer.addSubview(hostingController.view)
            
            NSLayoutConstraint.activate([
                hostingController.view.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
                hostingController.view.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor)
            ])
            
            self.artworkHostingController = hostingController
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        artworkHostingController?.rootView = ArtworkView(path: nil, size: .thumbnail, cornerRadius: 4)
    }
}

