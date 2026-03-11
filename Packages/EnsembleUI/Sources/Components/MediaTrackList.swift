import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit

// MARK: - Deferred Layout Table View

/// UITableView subclass that skips layout passes before being added to a window.
/// Prevents "UITableView layout outside view hierarchy" warnings when SwiftUI
/// eagerly creates table views for navigation destinations not yet displayed.
class DeferredLayoutTableView: UITableView {
    private var hasAppearedInWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !hasAppearedInWindow {
            hasAppearedInWindow = true
            // Trigger the first real layout now that we're in a window
            reloadData()
        }
    }

    override func layoutSubviews() {
        // Skip layout passes before the table is in a window — these cause
        // unnecessary work and "layout outside view hierarchy" warnings.
        guard window != nil else { return }
        super.layoutSubviews()
    }
}

// MARK: - Track Table View Cell

public class TrackTableViewCell: UITableViewCell {
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let downloadIcon = UIImageView()
    private let downloadSpinner = UIActivityIndicatorView(style: .medium)
    private let durationLabel = UILabel()
    private let playingIndicator = UIImageView()
    private let trackNumberLabel = UILabel()
    
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var subtitleLeadingConstraint: NSLayoutConstraint?
    private var downloadIconWidthConstraint: NSLayoutConstraint?
    private var downloadIconTrailingConstraint: NSLayoutConstraint?
    private var currentTrackID: String?
    private var artworkLoadTask: Task<Void, Never>?
    
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
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentView.addSubview(subtitleLabel)
        
        downloadIcon.image = UIImage(systemName: "arrow.down.circle.fill")
        downloadIcon.tintColor = .secondaryLabel
        downloadIcon.contentMode = .scaleAspectFit
        downloadIcon.translatesAutoresizingMaskIntoConstraints = false
        downloadIcon.isHidden = true
        downloadIcon.setContentHuggingPriority(.required, for: .horizontal)
        downloadIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(downloadIcon)

        downloadSpinner.hidesWhenStopped = true
        downloadSpinner.translatesAutoresizingMaskIntoConstraints = false
        downloadSpinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        contentView.addSubview(downloadSpinner)

        durationLabel.font = .systemFont(ofSize: 14, weight: .regular)
        durationLabel.textColor = .secondaryLabel
        durationLabel.textAlignment = .right
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadIcon.leadingAnchor, constant: -6),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadIcon.leadingAnchor, constant: -6),

            // Download icon / spinner sit just left of the duration label
            downloadIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            downloadIcon.heightAnchor.constraint(equalToConstant: 14),

            downloadSpinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            downloadSpinner.centerXAnchor.constraint(equalTo: downloadIcon.centerXAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            
            playingIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: 20),
            playingIndicator.heightAnchor.constraint(equalToConstant: 20)
        ])

        // Stored constraints toggled based on download state
        downloadIconWidthConstraint = downloadIcon.widthAnchor.constraint(equalToConstant: 0)
        downloadIconTrailingConstraint = downloadIcon.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor)
        downloadIconWidthConstraint?.isActive = true
        downloadIconTrailingConstraint?.isActive = true
    }
    
    public func configure(
        with track: Track,
        showArtwork: Bool,
        showTrackNumber: Bool,
        isPlaying: Bool,
        isUnavailableOffline: Bool,
        isActivelyDownloading: Bool = false,
        artworkLoader: ArtworkLoaderProtocol
    ) {
        titleLabel.text = track.title
        
        // Remove old constraints
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false
        
        // Configure leading constraint based on what's showing
        let leadingAnchor = showArtwork ? artworkImageView.trailingAnchor : (showTrackNumber ? trackNumberLabel.trailingAnchor : contentView.leadingAnchor)
        let constant: CGFloat = showArtwork || showTrackNumber ? 12 : 16
        
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        subtitleLeadingConstraint = subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        
        titleLeadingConstraint?.isActive = true
        subtitleLeadingConstraint?.isActive = true
        
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

        // Show spinner while downloading, download icon when complete, hide both otherwise
        if isActivelyDownloading {
            downloadIcon.isHidden = true
            downloadSpinner.startAnimating()
            downloadIconWidthConstraint?.constant = 14
            downloadIconTrailingConstraint?.constant = -4
        } else if track.isDownloaded {
            downloadIcon.isHidden = false
            downloadSpinner.stopAnimating()
            downloadIconWidthConstraint?.constant = 14
            downloadIconTrailingConstraint?.constant = -4
        } else {
            downloadIcon.isHidden = true
            downloadSpinner.stopAnimating()
            downloadIconWidthConstraint?.constant = 0
            downloadIconTrailingConstraint?.constant = 0
        }
        
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

        contentView.alpha = isUnavailableOffline ? 0.45 : 1
        
        // Load artwork if needed
        if showArtwork {
            // Only load artwork if track changed
            if currentTrackID != track.id {
                currentTrackID = track.id
                artworkImageView.backgroundColor = UIColor.systemGray5
                
                // Cancel any previous artwork load task
                artworkLoadTask?.cancel()
                
                artworkLoadTask = Task { @MainActor in
                guard let url = await artworkLoader.artworkURLAsync(
                    for: track.thumbPath,
                    sourceKey: track.sourceCompositeKey,
                    ratingKey: track.id,
                    fallbackPath: track.fallbackThumbPath,
                    fallbackRatingKey: track.fallbackRatingKey,
                    size: ArtworkSize.thumbnail.rawValue
                ) else {
                    // No artwork available - clear any stale image from cell reuse
                    if self.currentTrackID == track.id {
                        self.artworkImageView.image = nil
                    }
                    return
                }
                
                let request = ImageRequest(url: url)
                
                // Check cache first for instant display
                if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                    // Only update if still showing same track
                    if self.currentTrackID == track.id {
                        self.artworkImageView.image = cachedImage.image
                    }
                    return
                }
                
                // Load asynchronously if not cached
                if let image = try? await ImagePipeline.shared.image(for: request) {
                    // Only update if still showing same track
                    if self.currentTrackID == track.id {
                        self.artworkImageView.image = image
                    }
                }
            }
            } else {
                // Same track - just update playing state without reloading artwork
            }
        } else {
            currentTrackID = nil
            artworkImageView.image = nil
        }
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        // Cancel any in-flight artwork load
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentTrackID = nil
        // Don't clear the image - let the next configure() call handle it
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false
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
    let onPlayNext: ((Track) -> Void)?
    let onPlayLast: ((Track) -> Void)?
    let onAddToPlaylist: ((Track) -> Void)?
    let onAddToRecentPlaylist: ((Track) -> Void)?
    let onToggleFavorite: ((Track) -> Void)?
    let onGoToAlbum: ((Track) -> Void)?
    let onGoToArtist: ((Track) -> Void)?
    let onShareLink: ((Track) -> Void)?
    let onShareFile: ((Track) -> Void)?
    let isTrackFavorited: ((Track) -> Bool)?
    let canAddToRecentPlaylist: ((Track) -> Bool)?
    let recentPlaylistTitle: String?

    /// Change token from TrackAvailabilityResolver — parent observes the singleton
    /// and passes the generation here so MediaTrackList doesn't subscribe itself.
    let availabilityGeneration: UInt64
    /// Set of ratingKeys currently downloading — parent observes OfflineDownloadService once
    /// instead of N instances each subscribing to the singleton.
    let activeDownloadRatingKeys: Set<String>
    /// When true, the UITableView manages its own scrolling and cell recycling.
    /// When false (default), scroll is disabled and parent ScrollView handles scrolling.
    /// Use true for large track lists (>200 tracks) embedded in a detail view.
    let managesOwnScrolling: Bool
    /// Bottom content inset for the UITableView. Used with self-scrolling tables to
    /// allow content to scroll behind the mini player/tab bar (iOS blur-through effect).
    /// Only applies when managesOwnScrolling is true.
    let bottomContentInset: CGFloat

    @Environment(\.dependencies) private var dependencies

    public init(
        tracks: [Track],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        groupByDisc: Bool = false,
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        managesOwnScrolling: Bool = false,
        bottomContentInset: CGFloat = 0,
        onPlayNext: ((Track) -> Void)? = nil,
        onPlayLast: ((Track) -> Void)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onToggleFavorite: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        onShareLink: ((Track) -> Void)? = nil,
        onShareFile: ((Track) -> Void)? = nil,
        isTrackFavorited: ((Track) -> Bool)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.tracks = tracks
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.groupByDisc = groupByDisc
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadRatingKeys = activeDownloadRatingKeys
        self.managesOwnScrolling = managesOwnScrolling
        self.bottomContentInset = bottomContentInset
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToRecentPlaylist = onAddToRecentPlaylist
        self.onToggleFavorite = onToggleFavorite
        self.onGoToAlbum = onGoToAlbum
        self.onGoToArtist = onGoToArtist
        self.onShareLink = onShareLink
        self.onShareFile = onShareFile
        self.isTrackFavorited = isTrackFavorited
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
        self.onTrackTap = onTrackTap
    }
    
    public func makeUIView(context: Context) -> UITableView {
        let tableView: UITableView
        if managesOwnScrolling {
            // Regular UITableView — manages its own scrolling and cell recycling.
            // Used for large track lists where IntrinsicTableView would force all
            // cells to render simultaneously.
            tableView = UITableView(frame: .zero, style: .plain)
        } else {
            // DeferredLayoutTableView — parent ScrollView handles scrolling.
            tableView = DeferredLayoutTableView(frame: .zero, style: .plain)
        }
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
        tableView.backgroundColor = .clear
        tableView.isScrollEnabled = managesOwnScrolling

        // Disable automatic content inset adjustment — the table view is already
        // positioned below the nav bar by SwiftUI, so letting UIKit also adjust
        // contentInset.top causes a contentOffset shift that clips the last row.
        tableView.contentInsetAdjustmentBehavior = .never

        // Suppress any default section footer height so the content height stays
        // exactly N × rowHeight with no extra trailing space.
        tableView.sectionFooterHeight = 0

        // iOS 15 introduced automatic top padding above section headers; suppress it
        // so the content height is exactly N × rowHeight with no leading offset.
        tableView.sectionHeaderTopPadding = 0

        // Bottom content inset for scroll-behind-chrome behavior.
        // Lets content scroll behind mini player/tab bar with blur effect.
        if managesOwnScrolling && bottomContentInset > 0 {
            tableView.contentInset.bottom = bottomContentInset
        }

        // Enable drag-and-drop for downloaded tracks on iPad
        tableView.dragDelegate = context.coordinator
        tableView.dragInteractionEnabled = true

        return tableView
    }
    
    public func updateUIView(_ tableView: UITableView, context: Context) {
        let newGroupedTracks = groupByDisc ? groupTracksByDisc(tracks) : [(disc: nil, tracks: tracks)]
        
        // Check if track list structure changed (additions/removals/reordering)
        let dataChanged = context.coordinator.tracks.count != tracks.count ||
            !zip(context.coordinator.tracks, tracks).allSatisfy { $0.id == $1.id }

        // Check if any track's download state changed (localFilePath set or cleared)
        let downloadStateChanged = !dataChanged &&
            !zip(context.coordinator.tracks, tracks).allSatisfy { $0.isDownloaded == $1.isDownloaded }

        let currentTrackChanged = context.coordinator.currentTrackId != currentTrackId
        // Read network state from DependencyContainer (not observed — parent drives re-renders)
        let isOffline = !dependencies.networkMonitor.isConnected
        let offlineStateChanged = context.coordinator.isOffline != isOffline
        let activeDownloadsChanged = context.coordinator.activeDownloadRatingKeys != activeDownloadRatingKeys
        let availabilityChanged = context.coordinator.lastAvailabilityGeneration != availabilityGeneration

        // Update coordinator state
        context.coordinator.tracks = tracks
        context.coordinator.groupedTracks = newGroupedTracks
        context.coordinator.showArtwork = showArtwork
        context.coordinator.showTrackNumbers = showTrackNumbers
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.onTrackTap = onTrackTap
        context.coordinator.onPlayNext = onPlayNext
        context.coordinator.onPlayLast = onPlayLast
        context.coordinator.onAddToPlaylist = onAddToPlaylist
        context.coordinator.onAddToRecentPlaylist = onAddToRecentPlaylist
        context.coordinator.onToggleFavorite = onToggleFavorite
        context.coordinator.onGoToAlbum = onGoToAlbum
        context.coordinator.onGoToArtist = onGoToArtist
        context.coordinator.onShareLink = onShareLink
        context.coordinator.onShareFile = onShareFile
        context.coordinator.isTrackFavorited = isTrackFavorited
        context.coordinator.canAddToRecentPlaylist = canAddToRecentPlaylist
        context.coordinator.recentPlaylistTitle = recentPlaylistTitle
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.isOffline = isOffline
        context.coordinator.activeDownloadRatingKeys = activeDownloadRatingKeys
        context.coordinator.lastAvailabilityGeneration = availabilityGeneration

        // Skip reloads when the table isn't in a window yet — DeferredLayoutTableView
        // will trigger reloadData() on didMoveToWindow to avoid early layout passes.
        guard tableView.window != nil else { return }

        // Only reload if data actually changed
        if dataChanged {
            tableView.reloadData()
            // 🐛 TEMP: log geometry after reload to diagnose clipping
            DispatchQueue.main.async {
                #if DEBUG
                EnsembleLogger.debug("🐛 MediaTrackList frame=\(tableView.frame) contentSize=\(tableView.contentSize) contentInset=\(tableView.contentInset) contentOffset=\(tableView.contentOffset) adjustedInset=\(tableView.adjustedContentInset) rows=\(self.tracks.count)")
                #endif
            }
        } else if currentTrackChanged || offlineStateChanged || downloadStateChanged || activeDownloadsChanged || availabilityChanged {
            // Reconfigure visible cells when the playing track, connectivity, or download state changes.
            tableView.visibleCells.forEach { cell in
                if let trackCell = cell as? TrackTableViewCell,
                   let indexPath = tableView.indexPath(for: cell) {
                    let track = newGroupedTracks[indexPath.section].tracks[indexPath.row]
                    let isPlaying = track.id == currentTrackId
                    trackCell.configure(
                        with: track,
                        showArtwork: showArtwork,
                        showTrackNumber: showTrackNumbers,
                        isPlaying: isPlaying,
                        isUnavailableOffline: context.coordinator.trackAvailabilityResolver.availability(for: track).shouldDim,
                        isActivelyDownloading: context.coordinator.activeDownloadRatingKeys.contains(track.id),
                        artworkLoader: dependencies.artworkLoader
                    )
                }
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            tracks: tracks,
            groupedTracks: groupByDisc ? groupTracksByDisc(tracks) : [(disc: nil, tracks: tracks)],
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            currentTrackId: currentTrackId,
            onTrackTap: onTrackTap,
            onPlayNext: onPlayNext,
            onPlayLast: onPlayLast,
            onAddToPlaylist: onAddToPlaylist,
            onAddToRecentPlaylist: onAddToRecentPlaylist,
            onToggleFavorite: onToggleFavorite,
            onGoToAlbum: onGoToAlbum,
            onGoToArtist: onGoToArtist,
            onShareLink: onShareLink,
            onShareFile: onShareFile,
            isTrackFavorited: isTrackFavorited,
            canAddToRecentPlaylist: canAddToRecentPlaylist,
            recentPlaylistTitle: recentPlaylistTitle,
            artworkLoader: dependencies.artworkLoader,
            toastCenter: dependencies.toastCenter,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            isOffline: !dependencies.networkMonitor.isConnected,
            activeDownloadRatingKeys: activeDownloadRatingKeys
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
    
    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate {
        var tracks: [Track]
        var groupedTracks: [(disc: Int?, tracks: [Track])]
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var currentTrackId: String?
        var onTrackTap: (Track, Int) -> Void
        var onPlayNext: ((Track) -> Void)?
        var onPlayLast: ((Track) -> Void)?
        var onAddToPlaylist: ((Track) -> Void)?
        var onAddToRecentPlaylist: ((Track) -> Void)?
        var onToggleFavorite: ((Track) -> Void)?
        var onGoToAlbum: ((Track) -> Void)?
        var onGoToArtist: ((Track) -> Void)?
        var onShareLink: ((Track) -> Void)?
        var onShareFile: ((Track) -> Void)?
        var isTrackFavorited: ((Track) -> Bool)?
        var canAddToRecentPlaylist: ((Track) -> Bool)?
        var recentPlaylistTitle: String?
        var artworkLoader: ArtworkLoaderProtocol
        var toastCenter: ToastCenter
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var isOffline: Bool
        var activeDownloadRatingKeys: Set<String>
        var lastAvailabilityGeneration: UInt64 = 0

        init(
            tracks: [Track],
            groupedTracks: [(disc: Int?, tracks: [Track])],
            showArtwork: Bool,
            showTrackNumbers: Bool,
            currentTrackId: String?,
            onTrackTap: @escaping (Track, Int) -> Void,
            onPlayNext: ((Track) -> Void)?,
            onPlayLast: ((Track) -> Void)?,
            onAddToPlaylist: ((Track) -> Void)?,
            onAddToRecentPlaylist: ((Track) -> Void)?,
            onToggleFavorite: ((Track) -> Void)?,
            onGoToAlbum: ((Track) -> Void)?,
            onGoToArtist: ((Track) -> Void)?,
            onShareLink: ((Track) -> Void)?,
            onShareFile: ((Track) -> Void)?,
            isTrackFavorited: ((Track) -> Bool)?,
            canAddToRecentPlaylist: ((Track) -> Bool)?,
            recentPlaylistTitle: String?,
            artworkLoader: ArtworkLoaderProtocol,
            toastCenter: ToastCenter,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            isOffline: Bool,
            activeDownloadRatingKeys: Set<String> = []
        ) {
            self.tracks = tracks
            self.groupedTracks = groupedTracks
            self.showArtwork = showArtwork
            self.showTrackNumbers = showTrackNumbers
            self.currentTrackId = currentTrackId
            self.onTrackTap = onTrackTap
            self.onPlayNext = onPlayNext
            self.onPlayLast = onPlayLast
            self.onAddToPlaylist = onAddToPlaylist
            self.onAddToRecentPlaylist = onAddToRecentPlaylist
            self.onToggleFavorite = onToggleFavorite
            self.onGoToAlbum = onGoToAlbum
            self.onGoToArtist = onGoToArtist
            self.onShareLink = onShareLink
            self.onShareFile = onShareFile
            self.isTrackFavorited = isTrackFavorited
            self.canAddToRecentPlaylist = canAddToRecentPlaylist
            self.recentPlaylistTitle = recentPlaylistTitle
            self.artworkLoader = artworkLoader
            self.toastCenter = toastCenter
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.isOffline = isOffline
            self.activeDownloadRatingKeys = activeDownloadRatingKeys
        }
        
        public func numberOfSections(in tableView: UITableView) -> Int {
            groupedTracks.count
        }
        
        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            groupedTracks[section].tracks.count
        }
        
        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "TrackCell", for: indexPath) as! TrackTableViewCell
            cell.backgroundColor = .clear
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            let isPlaying = track.id == currentTrackId
            cell.configure(
                with: track,
                showArtwork: showArtwork,
                showTrackNumber: showTrackNumbers,
                isPlaying: isPlaying,
                isUnavailableOffline: trackAvailabilityResolver.availability(for: track).shouldDim,
                isActivelyDownloading: activeDownloadRatingKeys.contains(track.id),
                artworkLoader: artworkLoader
            )
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            return nil
        }
        
        public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            guard let disc = groupedTracks[section].disc else { return nil }
            
            let headerView = UIView()
            headerView.backgroundColor = .clear
            
            let label = UILabel()
            label.text = "Disc \(disc)"
            label.font = .systemFont(ofSize: 14, weight: .bold)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            
            headerView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
                label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                label.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16)
            ])
            
            return headerView
        }
        
        public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            return groupedTracks[section].disc != nil ? 40 : 0
        }

        public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            return 0
        }
        
        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]

            let availability = trackAvailabilityResolver.availability(for: track)
            if !availability.canPlay {
                Task { @MainActor in
                    toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "wifi.slash",
                            title: availability.userMessage ?? "Not available offline",
                            message: "Download this track before going offline.",
                            dedupeKey: "table-offline-track-blocked-\(track.id)"
                        )
                    )
                }
                return
            }
            
            // Find the global index in the full track list
            let globalIndex = tracks.firstIndex(where: { $0.id == track.id }) ?? 0
            onTrackTap(track, globalIndex)
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            68
        }
        
        public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            // Only show context menu if at least one callback is provided
            guard onPlayNext != nil || onPlayLast != nil || onAddToPlaylist != nil || onAddToRecentPlaylist != nil || onToggleFavorite != nil || onGoToAlbum != nil || onGoToArtist != nil || onShareLink != nil || onShareFile != nil else { return nil }
            
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var topActions: [UIAction] = []
                
                if let onPlayNext = self?.onPlayNext {
                    topActions.append(UIAction(title: "Play Next", image: UIImage(systemName: "text.insert")) { _ in
                        onPlayNext(track)
                    })
                }
                
                if let onPlayLast = self?.onPlayLast {
                    topActions.append(UIAction(title: "Play Last", image: UIImage(systemName: "text.append")) { _ in
                        onPlayLast(track)
                    })
                }
                
                var navigationActions: [UIAction] = []
                if let onGoToAlbum = self?.onGoToAlbum, track.albumRatingKey != nil {
                    navigationActions.append(UIAction(title: "Go to Album", image: UIImage(systemName: "square.stack")) { _ in
                        onGoToAlbum(track)
                    })
                }
                if let onGoToArtist = self?.onGoToArtist, track.artistRatingKey != nil {
                    navigationActions.append(UIAction(title: "Go to Artist", image: UIImage(systemName: "person.circle")) { _ in
                        onGoToArtist(track)
                    })
                }

                var bottomActions: [UIAction] = []
                if let onAddToRecentPlaylist = self?.onAddToRecentPlaylist,
                   let canAddToRecentPlaylist = self?.canAddToRecentPlaylist,
                   canAddToRecentPlaylist(track),
                   let recentPlaylistTitle = self?.recentPlaylistTitle {
                    bottomActions.append(UIAction(title: "Add to \(recentPlaylistTitle)", image: UIImage(systemName: "clock.arrow.circlepath")) { _ in
                        onAddToRecentPlaylist(track)
                    })
                }

                if let onAddToPlaylist = self?.onAddToPlaylist {
                    bottomActions.append(UIAction(title: "Add to Playlist…", image: UIImage(systemName: "text.badge.plus")) { _ in
                        onAddToPlaylist(track)
                    })
                }

                if let onToggleFavorite = self?.onToggleFavorite {
                    let isFavorited = self?.isTrackFavorited?(track) ?? (track.rating >= 8)
                    bottomActions.append(UIAction(
                        title: isFavorited ? "Unfavorite" : "Favorite",
                        image: UIImage(systemName: isFavorited ? "heart.slash" : "heart")
                    ) { _ in
                        onToggleFavorite(track)
                    })
                }
                
                // Share actions
                var shareActions: [UIAction] = []
                if let onShareLink = self?.onShareLink {
                    shareActions.append(UIAction(title: "Share Link…", image: UIImage(systemName: "link")) { _ in
                        onShareLink(track)
                    })
                }
                if let onShareFile = self?.onShareFile {
                    shareActions.append(UIAction(title: "Share Audio File…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        onShareFile(track)
                    })
                }

                var children: [UIMenuElement] = []
                if !topActions.isEmpty {
                    children.append(UIMenu(title: "", options: .displayInline, children: topActions))
                }
                if !navigationActions.isEmpty {
                    children.append(UIMenu(title: "", options: .displayInline, children: navigationActions))
                }
                if !bottomActions.isEmpty {
                    children.append(UIMenu(title: "", options: .displayInline, children: bottomActions))
                }
                if !shareActions.isEmpty {
                    children.append(UIMenu(title: "", options: .displayInline, children: shareActions))
                }

                return UIMenu(children: children)
            }
        }

        // MARK: - Drag Delegate (iPad drag-and-drop for downloaded tracks)

        public func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            guard let path = track.localFilePath else { return [] }
            let fileURL = URL(fileURLWithPath: path)
            guard let provider = NSItemProvider(contentsOf: fileURL) else { return [] }
            if let artist = track.artistName {
                provider.suggestedName = "\(artist) - \(track.title)"
            } else {
                provider.suggestedName = track.title
            }
            let dragItem = UIDragItem(itemProvider: provider)
            dragItem.localObject = track
            return [dragItem]
        }

        // MARK: - Swipe Actions

        public func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            let configured = DependencyContainer.shared.settingsManager.trackSwipeLayout.leading
            let actions = swipeActions(from: configured, track: track)
            guard !actions.isEmpty else { return nil }

            let configuration = UISwipeActionsConfiguration(actions: actions)
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }

        public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            let track = groupedTracks[indexPath.section].tracks[indexPath.row]
            let configured = DependencyContainer.shared.settingsManager.trackSwipeLayout.trailing
            let actions = swipeActions(from: configured, track: track)
            guard !actions.isEmpty else { return nil }

            let configuration = UISwipeActionsConfiguration(actions: actions)
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }

        private func swipeActions(from configured: [TrackSwipeAction?], track: Track) -> [UIContextualAction] {
            configured.compactMap { candidate in
                guard let action = candidate, isSwipeActionSupported(action) else { return nil }
                let contextual = UIContextualAction(style: .normal, title: swipeTitle(for: action, track: track)) { [weak self] _, _, completion in
                    self?.executeSwipeAction(action, track: track)
                    completion(true)
                }
                contextual.backgroundColor = UIColor(swipeTint(for: action, track: track))
                contextual.image = UIImage(systemName: swipeIcon(for: action, track: track))
                return contextual
            }
        }

        private func isSwipeActionSupported(_ action: TrackSwipeAction) -> Bool {
            switch action {
            case .playNext:
                return onPlayNext != nil
            case .playLast:
                return onPlayLast != nil
            case .addToPlaylist:
                return onAddToPlaylist != nil
            case .favoriteToggle:
                return onToggleFavorite != nil
            }
        }

        private func executeSwipeAction(_ action: TrackSwipeAction, track: Track) {
            switch action {
            case .playNext:
                onPlayNext?(track)
                showSwipeConfirmation(for: action, track: track)
            case .playLast:
                onPlayLast?(track)
                showSwipeConfirmation(for: action, track: track)
            case .addToPlaylist:
                onAddToPlaylist?(track)
                showSwipeConfirmation(for: action, track: track)
            case .favoriteToggle:
                let isFavorited = isTrackFavorited?(track) ?? (track.rating >= 8)
                showFavoriteLoadingToast(for: track, willFavorite: !isFavorited)
                onToggleFavorite?(track)
            }
        }

        private func showSwipeConfirmation(for action: TrackSwipeAction, track: Track) {
            let toast: ToastPayload

            switch action {
            case .playNext:
                toast = ToastPayload(
                    style: .success,
                    iconSystemName: "text.insert",
                    title: "Play Next",
                    message: "Added \(track.title).",
                    dedupeKey: "swipe-play-next-\(track.id)"
                )
            case .playLast:
                toast = ToastPayload(
                    style: .success,
                    iconSystemName: "text.append",
                    title: "Play Last",
                    message: "Queued \(track.title) for later.",
                    dedupeKey: "swipe-play-last-\(track.id)"
                )
            case .addToPlaylist:
                toast = ToastPayload(
                    style: .info,
                    iconSystemName: "text.badge.plus",
                    title: "Add to Playlist…",
                    message: "Choose a playlist to continue.",
                    dedupeKey: "swipe-add-to-playlist-\(track.id)"
                )
            case .favoriteToggle:
                return
            }

            Task { @MainActor in
                toastCenter.show(toast)
            }
        }

        private func showFavoriteLoadingToast(for track: Track, willFavorite: Bool) {
            let toast = ToastPayload(
                style: .info,
                iconSystemName: willFavorite ? "heart.fill" : "heart.slash.fill",
                title: willFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
                message: track.title,
                duration: 1.0,
                dedupeKey: "favorite-toggle-loading-\(track.id)",
                showsActivityIndicator: true
            )
            Task { @MainActor in
                toastCenter.show(toast)
            }
        }

        private func swipeTitle(for action: TrackSwipeAction, track: Track) -> String {
            switch action {
            case .favoriteToggle:
                let isFavorited = isTrackFavorited?(track) ?? (track.rating >= 8)
                return isFavorited ? "Unfavorite" : "Favorite"
            default:
                return action.title
            }
        }

        private func swipeIcon(for action: TrackSwipeAction, track: Track) -> String {
            switch action {
            case .favoriteToggle:
                let isFavorited = isTrackFavorited?(track) ?? (track.rating >= 8)
                return isFavorited ? "heart.slash.fill" : "heart.fill"
            default:
                return action.systemImage
            }
        }

        private func swipeTint(for action: TrackSwipeAction, track: Track) -> Color {
            switch action {
            case .favoriteToggle:
                let isFavorited = isTrackFavorited?(track) ?? (track.rating >= 8)
                return isFavorited ? .gray : .pink
            default:
                return action.tint
            }
        }
    }
}
#endif
