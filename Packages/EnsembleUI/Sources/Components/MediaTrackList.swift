import EnsembleCore
import SwiftUI
import Nuke

// MARK: - Track Table View Cell

public class TrackTableViewCell: UITableViewCell {
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingIndicator = UIImageView()
    private let trackNumberLabel = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkImageView.layer.cornerRadius = 4
        artworkImageView.backgroundColor = UIColor.systemGray5
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artworkImageView)
        
        trackNumberLabel.font = .systemFont(ofSize: 14, weight: .regular)
        trackNumberLabel.textColor = .secondaryLabel
        trackNumberLabel.textAlignment = .center
        trackNumberLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(trackNumberLabel)
        
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
            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 44),
            artworkImageView.heightAnchor.constraint(equalToConstant: 44),
            
            trackNumberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            trackNumberLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            trackNumberLabel.widthAnchor.constraint(equalToConstant: 30),
            
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            
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
    
    public func configure(
        with track: Track,
        showArtwork: Bool,
        showTrackNumber: Bool,
        isPlaying: Bool,
        artworkLoader: ArtworkLoaderProtocol
    ) {
        titleLabel.text = track.title
        
        // Configure leading constraint based on what's showing
        titleLabel.leadingAnchor.constraint(equalTo: showArtwork ? artworkImageView.trailingAnchor : (showTrackNumber ? trackNumberLabel.trailingAnchor : contentView.leadingAnchor), constant: showArtwork || showTrackNumber ? 12 : 16).isActive = true
        subtitleLabel.leadingAnchor.constraint(equalTo: showArtwork ? artworkImageView.trailingAnchor : (showTrackNumber ? trackNumberLabel.trailingAnchor : contentView.leadingAnchor), constant: showArtwork || showTrackNumber ? 12 : 16).isActive = true
        
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
        
        // Show/hide artwork
        artworkImageView.isHidden = !showArtwork
        
        // Show/hide track number
        trackNumberLabel.isHidden = !showTrackNumber
        if showTrackNumber {
            if isPlaying {
                trackNumberLabel.text = ""
                // Could add a playing indicator here if desired
            } else {
                trackNumberLabel.text = "\(track.trackNumber)"
            }
        }
        
        // Load artwork if needed
        if showArtwork {
            artworkImageView.image = nil
            artworkImageView.backgroundColor = UIColor.systemGray5
            
            Task { @MainActor in
                guard let url = await artworkLoader.artworkURLAsync(
                    for: track.thumbPath,
                    sourceKey: track.sourceCompositeKey,
                    size: ArtworkSize.thumbnail.rawValue
                ) else {
                    return
                }
                
                let request = ImageRequest(url: url)
                if let image = try? await ImagePipeline.shared.image(for: request) {
                    self.artworkImageView.image = image
                }
            }
        }
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        artworkImageView.image = nil
        
        // Remove all dynamic constraints
        for constraint in titleLabel.constraints {
            constraint.isActive = false
        }
        for constraint in subtitleLabel.constraints {
            constraint.isActive = false
        }
    }
}

// MARK: - Media Track List

public struct MediaTrackList: UIViewRepresentable {
    let tracks: [Track]
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let groupByDisc: Bool
    let currentTrackId: String?
    let onTrackTap: (Track, Int) -> Void
    
    @Environment(\.dependencies) private var dependencies
    
    public init(
        tracks: [Track],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        groupByDisc: Bool = false,
        currentTrackId: String? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.tracks = tracks
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.groupByDisc = groupByDisc
        self.currentTrackId = currentTrackId
        self.onTrackTap = onTrackTap
    }
    
    public func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.register(TrackTableViewCell.self, forCellReuseIdentifier: "TrackCell")
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: showArtwork ? 68 : (showTrackNumbers ? 54 : 16),
            bottom: 0,
            right: 0
        )
        tableView.backgroundColor = .systemBackground
        return tableView
    }
    
    public func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.tracks = tracks
        context.coordinator.groupedTracks = groupByDisc ? groupTracksByDisc(tracks) : [(disc: nil, tracks: tracks)]
        context.coordinator.showArtwork = showArtwork
        context.coordinator.showTrackNumbers = showTrackNumbers
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.onTrackTap = onTrackTap
        context.coordinator.artworkLoader = dependencies.artworkLoader
        tableView.reloadData()
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            tracks: tracks,
            groupedTracks: groupByDisc ? groupTracksByDisc(tracks) : [(disc: nil, tracks: tracks)],
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            currentTrackId: currentTrackId,
            onTrackTap: onTrackTap,
            artworkLoader: dependencies.artworkLoader
        )
    }
    
    private func groupTracksByDisc(_ tracks: [Track]) -> [(disc: Int?, tracks: [Track])] {
        let grouped = Dictionary(grouping: tracks) { $0.discNumber }
        let sortedKeys = grouped.keys.sorted()
        
        // Only show disc numbers if there are multiple discs
        let showDiscNumbers = sortedKeys.count > 1
        
        return sortedKeys.map { disc in
            (disc: showDiscNumbers ? disc : nil, tracks: grouped[disc] ?? [])
        }
    }
    
    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource {
        var tracks: [Track]
        var groupedTracks: [(disc: Int?, tracks: [Track])]
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var currentTrackId: String?
        var onTrackTap: (Track, Int) -> Void
        var artworkLoader: ArtworkLoaderProtocol
        
        init(
            tracks: [Track],
            groupedTracks: [(disc: Int?, tracks: [Track])],
            showArtwork: Bool,
            showTrackNumbers: Bool,
            currentTrackId: String?,
            onTrackTap: @escaping (Track, Int) -> Void,
            artworkLoader: ArtworkLoaderProtocol
        ) {
            self.tracks = tracks
            self.groupedTracks = groupedTracks
            self.showArtwork = showArtwork
            self.showTrackNumbers = showTrackNumbers
            self.currentTrackId = currentTrackId
            self.onTrackTap = onTrackTap
            self.artworkLoader = artworkLoader
        }
        
        public func numberOfSections(in tableView: UITableView) -> Int {
            groupedTracks.count
        }
        
        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            groupedTracks[section].tracks.count
        }
        
        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "TrackCell", for: indexPath) as! TrackTableViewCell
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            let isPlaying = track.id == currentTrackId
            cell.configure(
                with: track,
                showArtwork: showArtwork,
                showTrackNumber: showTrackNumbers,
                isPlaying: isPlaying,
                artworkLoader: artworkLoader
            )
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            if let disc = groupedTracks[section].disc {
                return "Disc \(disc)"
            }
            return nil
        }
        
        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            
            // Find the global index in the full track list
            let globalIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
            onTrackTap(track, globalIndex)
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            68
        }
    }
}
