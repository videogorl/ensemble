import EnsembleCore
import SwiftUI

func trackIdentityOrderMatches(_ lhs: [Track], _ rhs: [Track]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.sourceScopedID == $1.sourceScopedID }
}

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

fileprivate struct MediaTrackGroup {
    let id: String
    let title: String?
    let tracks: [Track]
    let isIndexable: Bool

    var signature: String {
        "\(id)|\(title ?? "")|\(tracks.count)|\(isIndexable)"
    }
}

// MARK: - Track Table View Cell

public class TrackTableViewCell: UITableViewCell {
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let artistMetadataLabel = UILabel()
    private let albumMetadataLabel = UILabel()
    private let downloadIcon = UIImageView()
    private let downloadSpinner = UIActivityIndicatorView(style: .medium)
    private let durationLabel = UILabel()
    private let overflowButton = UIButton(type: .system)
    private let playingIndicator = UIImageView()
    private let trackNumberLabel = UILabel()
    private let favoriteHeartView = UIImageView()

    private var artworkWidthConstraint: NSLayoutConstraint?
    private var artworkHeightConstraint: NSLayoutConstraint?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var subtitleLeadingConstraint: NSLayoutConstraint?
    private var titleTrailingToDownloadConstraint: NSLayoutConstraint?
    private var subtitleTrailingToDownloadConstraint: NSLayoutConstraint?
    private var titleTrailingToArtistConstraint: NSLayoutConstraint?
    private var artistTrailingToAlbumConstraint: NSLayoutConstraint?
    private var artistTrailingToDownloadConstraint: NSLayoutConstraint?
    private var albumTrailingToDownloadConstraint: NSLayoutConstraint?
    private var artistWidthConstraint: NSLayoutConstraint?
    private var albumWidthConstraint: NSLayoutConstraint?
    private var titleTopConstraint: NSLayoutConstraint?
    private var titleCenterYConstraint: NSLayoutConstraint?
    private var subtitleTopConstraint: NSLayoutConstraint?
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

        artistMetadataLabel.font = .systemFont(ofSize: 16, weight: .regular)
        artistMetadataLabel.textColor = .secondaryLabel
        artistMetadataLabel.lineBreakMode = .byTruncatingTail
        artistMetadataLabel.translatesAutoresizingMaskIntoConstraints = false
        artistMetadataLabel.setContentHuggingPriority(.required, for: .horizontal)
        artistMetadataLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(artistMetadataLabel)

        albumMetadataLabel.font = .systemFont(ofSize: 16, weight: .regular)
        albumMetadataLabel.textColor = .secondaryLabel
        albumMetadataLabel.lineBreakMode = .byTruncatingTail
        albumMetadataLabel.translatesAutoresizingMaskIntoConstraints = false
        albumMetadataLabel.setContentHuggingPriority(.required, for: .horizontal)
        albumMetadataLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentView.addSubview(albumMetadataLabel)
        
        downloadIcon.image = UIImage(systemName: EnsembleDesign.Icon.downloaded)
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

        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        let overflowSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        overflowButton.setPreferredSymbolConfiguration(overflowSymbolConfiguration, forImageIn: .normal)
        overflowButton.setImage(UIImage(systemName: EnsembleDesign.Icon.trackActions, withConfiguration: overflowSymbolConfiguration), for: .normal)
        overflowButton.tintColor = .secondaryLabel
        overflowButton.showsMenuAsPrimaryAction = true
        overflowButton.setContentHuggingPriority(.required, for: .horizontal)
        overflowButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        overflowButton.accessibilityLabel = "Track Actions"
        contentView.addSubview(overflowButton)
        
        playingIndicator.image = UIImage(systemName: EnsembleDesign.Icon.speakerPlaying)
        playingIndicator.tintColor = .systemBlue
        playingIndicator.contentMode = .scaleAspectFit
        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.isHidden = true
        contentView.addSubview(playingIndicator)

        // Favorite heart indicator (positioned in existing leading margin)
        favoriteHeartView.image = UIImage(systemName: EnsembleDesign.Icon.favoriteFilled)
        favoriteHeartView.tintColor = .systemPink
        favoriteHeartView.contentMode = .scaleAspectFit
        favoriteHeartView.translatesAutoresizingMaskIntoConstraints = false
        favoriteHeartView.isHidden = true
        contentView.addSubview(favoriteHeartView)

        NSLayoutConstraint.activate([
            // Heart centered in the 16pt leading margin, same size as download icon (14pt)
            favoriteHeartView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.favoriteIndicatorCenterX),
            favoriteHeartView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            favoriteHeartView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.favoriteIndicatorDimension),
            favoriteHeartView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.favoriteIndicatorDimension),

            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            trackNumberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding),
            trackNumberLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            trackNumberLabel.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.trackNumberWidth),

            artistMetadataLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            albumMetadataLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            // Download icon / spinner sit just left of the duration label
            downloadIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            downloadIcon.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension),

            downloadSpinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            downloadSpinner.centerXAnchor.constraint(equalTo: downloadIcon.centerXAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.durationColumnWidth),

            overflowButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding),
            overflowButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.overflowControlDimension),
            overflowButton.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.overflowControlDimension),
            
            playingIndicator.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension),
            playingIndicator.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension)
        ])

        artworkWidthConstraint = artworkImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension)
        artworkHeightConstraint = artworkImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension)
        titleTopConstraint = titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TrackListLayoutMetrics.defaultTitleTopPadding)
        titleCenterYConstraint = titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        subtitleTopConstraint = subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: TrackListLayoutMetrics.primarySecondaryTextSpacing)
        artworkWidthConstraint?.isActive = true
        artworkHeightConstraint?.isActive = true
        updateArtworkCornerRadius(for: TrackListLayoutMetrics.standardArtworkDimension)
        titleTopConstraint?.isActive = true
        subtitleTopConstraint?.isActive = true

        titleTrailingToDownloadConstraint = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadIcon.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap)
        subtitleTrailingToDownloadConstraint = subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: downloadIcon.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap)
        titleTrailingToArtistConstraint = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: artistMetadataLabel.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistTrailingToAlbumConstraint = artistMetadataLabel.trailingAnchor.constraint(equalTo: albumMetadataLabel.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistTrailingToDownloadConstraint = artistMetadataLabel.trailingAnchor.constraint(equalTo: downloadIcon.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        albumTrailingToDownloadConstraint = albumMetadataLabel.trailingAnchor.constraint(equalTo: downloadIcon.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistWidthConstraint = artistMetadataLabel.widthAnchor.constraint(equalToConstant: 0)
        albumWidthConstraint = albumMetadataLabel.widthAnchor.constraint(equalToConstant: 0)
        artistWidthConstraint?.isActive = true
        albumWidthConstraint?.isActive = true
        titleTrailingToDownloadConstraint?.isActive = true
        subtitleTrailingToDownloadConstraint?.isActive = true

        // Stored constraints toggled based on download state
        downloadIconWidthConstraint = downloadIcon.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension)
        downloadIconTrailingConstraint = downloadIcon.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap)
        downloadIconWidthConstraint?.isActive = true
        downloadIconTrailingConstraint?.isActive = true
    }
    
    public func configure(
        with track: Track,
        showArtwork: Bool,
        showTrackNumber: Bool,
        showAlbumName: Bool = true,
        isPlaying: Bool,
        isUnavailableOffline: Bool,
        isActivelyDownloading: Bool = false,
        isFavorited: Bool = false,
        supplementalMetadataWidth: CGFloat? = nil,
        menu: UIMenu?,
        rowHeight: CGFloat = 68,
        artworkLoader: ArtworkLoaderProtocol
    ) {
        applyLayoutMetrics(for: rowHeight)
        titleLabel.text = track.title
        overflowButton.menu = menu
        overflowButton.isHidden = menu == nil

        // Show/hide favorite heart (positioned in existing margin, no content shift)
        favoriteHeartView.isHidden = !isFavorited

        // Remove old constraints
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false

        // Configure leading constraint based on what's showing
        let leadingAnchor = showArtwork ? artworkImageView.trailingAnchor : (showTrackNumber ? trackNumberLabel.trailingAnchor : contentView.leadingAnchor)
        let constant: CGFloat = showArtwork || showTrackNumber
            ? TrackListLayoutMetrics.rowInterItemSpacing
            : TrackListLayoutMetrics.rowHorizontalPadding

        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        subtitleLeadingConstraint = subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)

        titleLeadingConstraint?.isActive = true
        subtitleLeadingConstraint?.isActive = true

        let showsArtistMetadataColumn = Self.showsArtistMetadataColumn(for: supplementalMetadataWidth)
        let showsAlbumMetadataColumn = Self.showsAlbumMetadataColumn(for: supplementalMetadataWidth)
        applySupplementalMetadataLayout(
            width: supplementalMetadataWidth,
            showsArtistColumn: showsArtistMetadataColumn,
            showsAlbumColumn: showsAlbumMetadataColumn
        )

        var subtitleParts: [String] = []
        if let artist = track.artistName {
            subtitleParts.append(artist)
        }
        if showAlbumName, let album = track.albumName {
            subtitleParts.append(album)
        }
        subtitleLabel.text = showsArtistMetadataColumn ? nil : subtitleParts.joined(separator: " · ")
        subtitleLabel.isHidden = showsArtistMetadataColumn
        artistMetadataLabel.text = track.artistName ?? "Unknown Artist"
        albumMetadataLabel.text = track.albumName ?? "Unknown Album"
        
        durationLabel.text = track.formattedDuration
        durationLabel.isHidden = isPlaying
        playingIndicator.isHidden = !isPlaying

        // Show spinner while downloading, download icon when complete, hide both otherwise
        if isActivelyDownloading {
            downloadIcon.isHidden = true
            downloadSpinner.startAnimating()
        } else if track.isDownloaded {
            downloadIcon.isHidden = false
            downloadSpinner.stopAnimating()
        } else {
            downloadIcon.isHidden = true
            downloadSpinner.stopAnimating()
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
            let playbackIdentity = track.playbackIdentity
            if currentTrackID != playbackIdentity {
                currentTrackID = playbackIdentity
                artworkImageView.backgroundColor = UIColor.systemGray5
                
                // Cancel any previous artwork load task
                artworkLoadTask?.cancel()
                
                artworkLoadTask = Task { @MainActor in
                    let image = await TrackArtworkThumbnailLoader.image(
                        for: track,
                        artworkLoader: artworkLoader
                    ) {
                        self.currentTrackID == playbackIdentity
                    }

                    if self.currentTrackID == playbackIdentity {
                        self.artworkImageView.image = image
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

    /// Keeps StageFlow's compact rows balanced without changing the default density elsewhere.
    private func applyLayoutMetrics(for rowHeight: CGFloat) {
        let isCompact = rowHeight <= TrackListLayoutMetrics.compactRowHeightThreshold

        let artworkDimension = isCompact
            ? TrackListLayoutMetrics.compactArtworkDimension
            : TrackListLayoutMetrics.standardArtworkDimension
        artworkWidthConstraint?.constant = artworkDimension
        artworkHeightConstraint?.constant = artworkDimension
        updateArtworkCornerRadius(for: artworkDimension)
        titleTopConstraint?.constant = isCompact
            ? TrackListLayoutMetrics.compactTitleTopPadding
            : TrackListLayoutMetrics.defaultTitleTopPadding
        subtitleTopConstraint?.constant = isCompact
            ? TrackListLayoutMetrics.primarySecondaryTextSpacing / 2
            : TrackListLayoutMetrics.primarySecondaryTextSpacing

        trackNumberLabel.font = .systemFont(
            ofSize: isCompact ? TrackListLayoutMetrics.nativeCompactSecondaryFontSize : TrackListLayoutMetrics.nativeSecondaryFontSize,
            weight: .regular
        )
        titleLabel.font = .systemFont(
            ofSize: isCompact ? TrackListLayoutMetrics.nativeCompactPrimaryFontSize : TrackListLayoutMetrics.nativePrimaryFontSize,
            weight: .regular
        )
        subtitleLabel.font = .systemFont(
            ofSize: isCompact ? TrackListLayoutMetrics.nativeCompactSecondaryFontSize : TrackListLayoutMetrics.nativeSecondaryFontSize,
            weight: .regular
        )
        durationLabel.font = .systemFont(
            ofSize: isCompact ? TrackListLayoutMetrics.nativeCompactSecondaryFontSize : TrackListLayoutMetrics.nativeSecondaryFontSize,
            weight: .regular
        )
    }

    private func updateArtworkCornerRadius(for dimension: CGFloat) {
        artworkImageView.layer.cornerRadius = ArtworkCornerRadius.square(for: dimension)
    }

    private func applySupplementalMetadataLayout(
        width: CGFloat?,
        showsArtistColumn: Bool,
        showsAlbumColumn: Bool
    ) {
        artistMetadataLabel.isHidden = !showsArtistColumn
        albumMetadataLabel.isHidden = !showsAlbumColumn
        artistWidthConstraint?.constant = showsArtistColumn ? Self.artistMetadataColumnWidth(for: width) : 0
        albumWidthConstraint?.constant = showsAlbumColumn ? Self.albumMetadataColumnWidth(for: width) : 0

        titleTopConstraint?.isActive = !showsArtistColumn
        titleCenterYConstraint?.isActive = showsArtistColumn
        titleTrailingToDownloadConstraint?.isActive = !showsArtistColumn
        titleTrailingToArtistConstraint?.isActive = showsArtistColumn
        artistTrailingToAlbumConstraint?.isActive = showsArtistColumn && showsAlbumColumn
        artistTrailingToDownloadConstraint?.isActive = showsArtistColumn && !showsAlbumColumn
        albumTrailingToDownloadConstraint?.isActive = showsAlbumColumn
    }

    private static func showsArtistMetadataColumn(for width: CGFloat?) -> Bool {
        guard let width else { return false }
        return TrackListLayoutMetrics.showsArtistMetadataColumn(for: width)
    }

    private static func showsAlbumMetadataColumn(for width: CGFloat?) -> Bool {
        guard let width else { return false }
        return TrackListLayoutMetrics.showsAlbumMetadataColumn(for: width)
    }

    private static func artistMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        TrackListLayoutMetrics.artistMetadataColumnWidth(for: width)
    }

    private static func albumMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        TrackListLayoutMetrics.albumMetadataColumnWidth(for: width)
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
    let sections: [NativeTrackListSection]?
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let showAlbumName: Bool
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
    let onGetInfo: ((Track) -> Void)?
    let onShareLink: ((Track) -> Void)?
    let onShareFile: ((Track) -> Void)?
    let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    let isTrackFavorited: ((Track) -> Bool)?
    let canAddToRecentPlaylist: ((Track) -> Bool)?
    let recentPlaylistTitle: String?
    let showsNativeSectionIndex: Bool
    let sectionScrollRequestID: Int?
    let sectionScrollTargetID: String?
    let interactionModel: TrackRowInteractionModel
    /// Optional available width used to reveal wide artist/album metadata columns.
    let supplementalMetadataWidth: CGFloat?

    /// Change token from TrackAvailabilityResolver — parent observes the singleton
    /// and passes the generation here so MediaTrackList doesn't subscribe itself.
    let availabilityGeneration: UInt64
    /// Set of ratingKeys currently downloading — parent observes OfflineDownloadService once
    /// instead of N instances each subscribing to the singleton.
    let activeDownloadTrackIdentities: Set<String>
    /// When true, the UITableView manages its own scrolling and cell recycling.
    /// When false (default), scroll is disabled and parent ScrollView handles scrolling.
    /// Use true for large track lists (>200 tracks) embedded in a detail view.
    let managesOwnScrolling: Bool
    /// Bottom content inset for the UITableView. Used with self-scrolling tables to
    /// allow content to scroll behind the mini player/tab bar (iOS blur-through effect).
    /// Only applies when managesOwnScrolling is true.
    let topContentInset: CGFloat
    let bottomContentInset: CGFloat
    /// Fixed height for each row. StageFlow uses a denser value while standard lists keep 68pt.
    let rowHeight: CGFloat
    /// Optional SwiftUI content to embed as the UITableView's `tableHeaderView`.
    /// Scrolls naturally with the table while preserving full cell recycling.
    /// Used by MediaDetailView to scroll album art + action buttons with the track list.
    let tableHeaderContent: AnyView?
    /// Optional SwiftUI content to embed as the UITableView's `tableFooterView`.
    /// Used to show loading/empty indicators below the track list while keeping
    /// the header (chips + artwork + buttons) structurally identical across all states.
    let tableFooterContent: AnyView?
    /// When provided, a UISearchController is attached to the navigation bar —
    /// hidden by default, revealed on pull-down like Apple Music / Settings.
    /// The binding syncs the search text back to the parent view model.
    let searchTextBinding: Binding<String>?

    @Environment(\.dependencies) private var dependencies
    @Environment(\.trackListDisplayRatingsRevision) private var displayRatingsRevision

    public init(
        tracks: [Track],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        showAlbumName: Bool = true,
        groupByDisc: Bool = false,
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        managesOwnScrolling: Bool = false,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        searchTextBinding: Binding<String>? = nil,
        interactionModel: TrackRowInteractionModel? = nil,
        supplementalMetadataWidth: CGFloat? = nil,
        onPlayNext: ((Track) -> Void)? = nil,
        onPlayLast: ((Track) -> Void)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onToggleFavorite: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        onGetInfo: ((Track) -> Void)? = nil,
        onShareLink: ((Track) -> Void)? = nil,
        onShareFile: ((Track) -> Void)? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        isTrackFavorited: ((Track) -> Bool)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.tracks = tracks
        self.sections = nil
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.showAlbumName = showAlbumName
        self.groupByDisc = groupByDisc
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.managesOwnScrolling = managesOwnScrolling
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.rowHeight = rowHeight
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.searchTextBinding = searchTextBinding
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToRecentPlaylist = onAddToRecentPlaylist
        self.onToggleFavorite = onToggleFavorite
        self.onGoToAlbum = onGoToAlbum
        self.onGoToArtist = onGoToArtist
        self.onGetInfo = onGetInfo
        self.onShareLink = onShareLink
        self.onShareFile = onShareFile
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.isTrackFavorited = isTrackFavorited
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
        self.showsNativeSectionIndex = false
        self.sectionScrollRequestID = nil
        self.sectionScrollTargetID = nil
        self.interactionModel = interactionModel ?? TrackRowInteractionModel(
            onPlayNext: onPlayNext,
            onPlayLast: onPlayLast,
            onAddToPlaylist: onAddToPlaylist,
            onAddToRecentPlaylist: onAddToRecentPlaylist,
            onToggleFavorite: onToggleFavorite,
            onGoToAlbum: onGoToAlbum,
            onGoToArtist: onGoToArtist,
            onGetInfo: onGetInfo,
            onShareLink: onShareLink,
            onShareFile: onShareFile,
            isTrackFavorited: isTrackFavorited,
            canAddToRecentPlaylist: canAddToRecentPlaylist,
            recentPlaylistTitle: recentPlaylistTitle
        )
        self.onTrackTap = onTrackTap
    }

    public init(
        sections: [NativeTrackListSection],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        showAlbumName: Bool = true,
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        tableHeaderContent: AnyView? = nil,
        tableFooterContent: AnyView? = nil,
        searchTextBinding: Binding<String>? = nil,
        interactionModel: TrackRowInteractionModel? = nil,
        supplementalMetadataWidth: CGFloat? = nil,
        showsNativeSectionIndex: Bool = false,
        sectionScrollRequestID: Int? = nil,
        sectionScrollTargetID: String? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.tracks = sections.flatMap(\.tracks)
        self.sections = sections
        self.showArtwork = showArtwork
        self.showTrackNumbers = showTrackNumbers
        self.showAlbumName = showAlbumName
        self.groupByDisc = false
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.managesOwnScrolling = true
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.rowHeight = rowHeight
        self.tableHeaderContent = tableHeaderContent
        self.tableFooterContent = tableFooterContent
        self.searchTextBinding = searchTextBinding
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.onPlayNext = nil
        self.onPlayLast = nil
        self.onAddToPlaylist = nil
        self.onAddToRecentPlaylist = nil
        self.onToggleFavorite = nil
        self.onGoToAlbum = nil
        self.onGoToArtist = nil
        self.onGetInfo = nil
        self.onShareLink = nil
        self.onShareFile = nil
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.isTrackFavorited = nil
        self.canAddToRecentPlaylist = nil
        self.recentPlaylistTitle = nil
        self.showsNativeSectionIndex = showsNativeSectionIndex
        self.sectionScrollRequestID = sectionScrollRequestID
        self.sectionScrollTargetID = sectionScrollTargetID
        self.interactionModel = interactionModel ?? TrackRowInteractionModel()
        self.onTrackTap = onTrackTap
    }
    
    public func makeUIView(context: Context) -> UITableView {
        let tableView: UITableView
        if managesOwnScrolling {
            // Regular UITableView — manages its own scrolling and cell recycling.
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
            left: TrackListLayoutMetrics.contentLeadingInset(
                showArtwork: showArtwork,
                showTrackNumbers: showTrackNumbers
            ),
            bottom: 0,
            right: 0
        )
        tableView.separatorColor = TrackListLayoutMetrics.nativeSeparatorColor
        tableView.backgroundColor = .clear
        tableView.isScrollEnabled = managesOwnScrolling

        // Self-scrolling tables extend under the nav bar (via .ignoresSafeArea on the
        // SwiftUI side) and use .automatic so UIKit adds the correct top content inset.
        // This lets content scroll behind the translucent navigation bar.
        // Non-scrolling tables embedded in a parent ScrollView use .never.
        tableView.contentInsetAdjustmentBehavior = managesOwnScrolling ? .automatic : .never

        // Suppress any default section footer height so the content height stays
        // exactly N × rowHeight with no extra trailing space.
        tableView.sectionFooterHeight = 0
        tableView.sectionIndexMinimumDisplayRowCount = 1
        tableView.sectionIndexColor = UIColor(EnsembleDesign.Color.accent)
        tableView.sectionIndexBackgroundColor = .clear
        tableView.sectionIndexTrackingBackgroundColor = .clear

        // iOS 15 introduced automatic top padding above section headers; suppress it
        // so the content height is exactly N × rowHeight with no leading offset.
        tableView.sectionHeaderTopPadding = 0

        // Content insets for scroll-behind-chrome behavior.
        // Lets content scroll behind mini player/tab bar with blur effect.
        if managesOwnScrolling && topContentInset > 0 {
            tableView.contentInset.top = topContentInset
        }
        if managesOwnScrolling && bottomContentInset > 0 {
            tableView.contentInset.bottom = bottomContentInset
        }

        // Enable drag-and-drop for downloaded tracks on iPad
        tableView.dragDelegate = context.coordinator
        tableView.dragInteractionEnabled = true

        // Install optional SwiftUI table header (album art, action buttons, etc.).
        // Uses UIHostingController to bridge SwiftUI content into the UITableView's
        // native tableHeaderView, which scrolls with the table and preserves cell recycling.
        if let tableHeaderContent {
            let hostingController = UIHostingController(rootView: tableHeaderContent)
            hostingController.view.backgroundColor = .clear
            // Size the header to fit its content
            let targetWidth = tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width
            let fittingSize = hostingController.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            hostingController.view.frame = CGRect(origin: .zero, size: fittingSize)
            tableView.tableHeaderView = hostingController.view
            context.coordinator.headerHostingController = hostingController
        }

        // Install optional SwiftUI table footer (loading/empty indicators).
        // Only set tableFooterView when the content has real height — an empty
        // hosting controller can interfere with bottomContentInset scroll-behind.
        if let tableFooterContent {
            let footerHost = UIHostingController(rootView: tableFooterContent)
            footerHost.view.backgroundColor = .clear
            let targetWidth = tableView.bounds.width > 0 ? tableView.bounds.width : UIScreen.main.bounds.width
            let fittingSize = footerHost.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            footerHost.view.frame = CGRect(origin: .zero, size: fittingSize)
            if fittingSize.height >= 1 {
                tableView.tableFooterView = footerHost.view
            }
            context.coordinator.footerHostingController = footerHost
        }

        // When a search binding is provided, set up a UISearchController once the
        // table is in the view hierarchy. Uses didMoveToWindow to find the hosting
        // UIViewController and attach the search controller to its navigation item.
        if let searchTextBinding {
            context.coordinator.pendingSearchBinding = searchTextBinding
            context.coordinator.pendingTableView = tableView
        }

        return tableView
    }
    
    public func updateUIView(_ tableView: UITableView, context: Context) {
        // Attach UISearchController once the table is in a window.
        // Must happen after the view is in the hierarchy so we can find the
        // hosting UIViewController and its navigation controller.
        if context.coordinator.pendingSearchBinding != nil && tableView.window != nil {
            context.coordinator.attachSearchController()
        }

        // Re-apply content insets if they were cleared. This can happen when
        // .automatic contentInsetAdjustmentBehavior recalculates insets as the table
        // enters the view hierarchy (e.g. a navigation controller or tab bar controller).
        if managesOwnScrolling && tableView.contentInset.top != topContentInset {
            tableView.contentInset.top = topContentInset
        }
        if managesOwnScrolling && bottomContentInset > 0 && tableView.contentInset.bottom != bottomContentInset {
            EnsembleLogger.debug("MediaTrackList re-applying bottomContentInset: was \(tableView.contentInset.bottom), setting to \(bottomContentInset)")
            tableView.contentInset.bottom = bottomContentInset
        }

        let newGroupedTracks = makeTrackGroups()
        
        // Check if track list structure changed (additions/removals/reordering)
        let newGroupSignature = newGroupedTracks.map(\.signature)
        let dataChanged = !trackIdentityOrderMatches(context.coordinator.tracks, tracks) ||
            context.coordinator.groupSignature != newGroupSignature

        // Check if any track's download state changed (localFilePath set or cleared)
        let downloadStateChanged = !dataChanged &&
            !zip(context.coordinator.tracks, tracks).allSatisfy { $0.isDownloaded == $1.isDownloaded }

        let currentTrackChanged = context.coordinator.currentTrackId != currentTrackId
        // Read network state from DependencyContainer (not observed — parent drives re-renders)
        let isOffline = !dependencies.networkMonitor.isConnected
        let offlineStateChanged = context.coordinator.isOffline != isOffline
        let activeDownloadsChanged = context.coordinator.activeDownloadTrackIdentities != activeDownloadTrackIdentities
        let availabilityChanged = context.coordinator.lastAvailabilityGeneration != availabilityGeneration
        let supplementalMetadataWidthChanged = context.coordinator.supplementalMetadataWidth != supplementalMetadataWidth
        let displayRatingsChanged = context.coordinator.lastDisplayRatingsRevision != displayRatingsRevision
        let newFavoriteStateSignature = favoriteStateSignature(for: tracks)
        let favoriteStateChanged = !dataChanged && (displayRatingsChanged || context.coordinator.favoriteStateSignature != newFavoriteStateSignature)

        // Update coordinator state
        context.coordinator.tracks = tracks
        context.coordinator.groupedTracks = newGroupedTracks
        context.coordinator.groupSignature = newGroupSignature
        context.coordinator.favoriteStateSignature = newFavoriteStateSignature
        context.coordinator.showArtwork = showArtwork
        context.coordinator.showTrackNumbers = showTrackNumbers
        context.coordinator.showAlbumName = showAlbumName
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.onTrackTap = onTrackTap
        context.coordinator.onPlayNext = onPlayNext
        context.coordinator.onPlayLast = onPlayLast
        context.coordinator.onAddToPlaylist = onAddToPlaylist
        context.coordinator.onAddToRecentPlaylist = onAddToRecentPlaylist
        context.coordinator.onToggleFavorite = onToggleFavorite
        context.coordinator.onGoToAlbum = onGoToAlbum
        context.coordinator.onGoToArtist = onGoToArtist
        context.coordinator.onGetInfo = onGetInfo
        context.coordinator.onShareLink = onShareLink
        context.coordinator.onShareFile = onShareFile
        context.coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        context.coordinator.isTrackFavorited = isTrackFavorited
        context.coordinator.canAddToRecentPlaylist = canAddToRecentPlaylist
        context.coordinator.recentPlaylistTitle = recentPlaylistTitle
        context.coordinator.showsNativeSectionIndex = showsNativeSectionIndex
        context.coordinator.interactionModel = interactionModel
        context.coordinator.supplementalMetadataWidth = supplementalMetadataWidth
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.settingsManager = dependencies.settingsManager
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.isOffline = isOffline
        context.coordinator.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        context.coordinator.rowHeight = rowHeight
        context.coordinator.lastAvailabilityGeneration = availabilityGeneration
        context.coordinator.lastDisplayRatingsRevision = displayRatingsRevision

        // Reload data immediately after updating groupedTracks to keep UIKit's geometry
        // in sync with the backing data. Previously there was a ~85 line gap between the
        // data assignment and reloadData(), during which delegate methods could fire with
        // stale index paths against the new (possibly shorter) data — causing crashes.
        if tableView.window != nil && dataChanged {
            tableView.reloadData()
            tableView.reloadSectionIndexTitles()
        }

        // Update table header view size if needed (e.g., after initial width becomes available).
        // UITableView requires explicit header resizing — it doesn't auto-layout the header.
        if let headerHost = context.coordinator.headerHostingController,
           let headerView = tableView.tableHeaderView,
           tableView.bounds.width > 0 {
            if let tableHeaderContent {
                headerHost.rootView = tableHeaderContent
            }
            let targetWidth = tableView.bounds.width
            let fittingSize = headerHost.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            // Only reassign when height actually changes to avoid layout loops
            if abs(headerView.frame.height - fittingSize.height) > 1 {
                headerView.frame = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: fittingSize.height))
                tableView.tableHeaderView = headerView
            }
        }

        // Update table footer view — dynamically add/remove based on content height.
        // An empty footer (EmptyView) must be removed entirely so it doesn't interfere
        // with bottomContentInset scroll-behind behavior (mini player / tab bar).
        if let footerHost = context.coordinator.footerHostingController,
           tableView.bounds.width > 0 {
            if let tableFooterContent {
                footerHost.rootView = tableFooterContent
            }
            let targetWidth = tableView.bounds.width
            let fittingSize = footerHost.view.systemLayoutSizeFitting(
                CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            if fittingSize.height < 1 {
                // Footer content is empty — remove to preserve scroll-behind inset
                if tableView.tableFooterView != nil {
                    tableView.tableFooterView = nil
                }
            } else if let footerView = tableView.tableFooterView {
                // Footer exists — resize if height changed
                if abs(footerView.frame.height - fittingSize.height) > 1 {
                    footerView.frame = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: fittingSize.height))
                    tableView.tableFooterView = footerView
                }
            } else {
                // Footer became non-empty — install it
                footerHost.view.frame = CGRect(origin: .zero, size: CGSize(width: targetWidth, height: fittingSize.height))
                tableView.tableFooterView = footerHost.view
            }
        }

        // Skip remaining work when the table isn't in a window yet — DeferredLayoutTableView
        // will trigger reloadData() on didMoveToWindow to avoid early layout passes.
        guard tableView.window != nil else { return }

        if let sectionScrollRequestID,
           context.coordinator.consumedSectionScrollRequestID != sectionScrollRequestID,
           let sectionScrollTargetID,
           let targetSection = context.coordinator.sectionIndex(forID: sectionScrollTargetID) {
            context.coordinator.consumedSectionScrollRequestID = sectionScrollRequestID
            tableView.layoutIfNeeded()
            if tableView.numberOfRows(inSection: targetSection) > 0 {
                tableView.scrollToRow(
                    at: IndexPath(row: 0, section: targetSection),
                    at: .top,
                    animated: false
                )
            } else {
                let headerRect = tableView.rectForHeader(inSection: targetSection)
                let targetOffset = max(-tableView.adjustedContentInset.top, headerRect.minY - tableView.adjustedContentInset.top)
                tableView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            }
        }

        if !dataChanged && (currentTrackChanged || offlineStateChanged || downloadStateChanged || activeDownloadsChanged || availabilityChanged || supplementalMetadataWidthChanged || favoriteStateChanged) {
            // Reconfigure visible cells when track state or adaptive metadata width changes.
            // Bounds-check indexPaths since visible cells may reference stale geometry.
            tableView.visibleCells.forEach { cell in
                if let trackCell = cell as? TrackTableViewCell,
                   let indexPath = tableView.indexPath(for: cell),
                   indexPath.section < newGroupedTracks.count,
                   indexPath.row < newGroupedTracks[indexPath.section].tracks.count {
                    let track = newGroupedTracks[indexPath.section].tracks[indexPath.row]
                    let isPlaying = track.playbackIdentity == currentTrackId
                    trackCell.configure(
                        with: track,
                        showArtwork: showArtwork,
                        showTrackNumber: showTrackNumbers,
                        showAlbumName: showAlbumName,
                        isPlaying: isPlaying,
                        isUnavailableOffline: context.coordinator.trackAvailabilityResolver.availability(for: track).shouldDim,
                        isActivelyDownloading: context.coordinator.activeDownloadTrackIdentities.contains(track.sourceScopedID),
                        isFavorited: context.coordinator.interactionModel.isFavorited(track),
                        supplementalMetadataWidth: context.coordinator.supplementalMetadataWidth,
                        menu: context.coordinator.makeDeferredContextMenu(for: track, at: indexPath),
                        rowHeight: context.coordinator.rowHeight,
                        artworkLoader: dependencies.artworkLoader
                    )
                }
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            tracks: tracks,
            groupedTracks: makeTrackGroups(),
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            showAlbumName: showAlbumName,
            currentTrackId: currentTrackId,
            onTrackTap: onTrackTap,
            onPlayNext: onPlayNext,
            onPlayLast: onPlayLast,
            onAddToPlaylist: onAddToPlaylist,
            onAddToRecentPlaylist: onAddToRecentPlaylist,
            onToggleFavorite: onToggleFavorite,
            onGoToAlbum: onGoToAlbum,
            onGoToArtist: onGoToArtist,
            onGetInfo: onGetInfo,
            onShareLink: onShareLink,
            onShareFile: onShareFile,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            isTrackFavorited: isTrackFavorited,
            canAddToRecentPlaylist: canAddToRecentPlaylist,
            recentPlaylistTitle: recentPlaylistTitle,
            showsNativeSectionIndex: showsNativeSectionIndex,
            interactionModel: interactionModel,
            supplementalMetadataWidth: supplementalMetadataWidth,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            settingsManager: dependencies.settingsManager,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            isOffline: !dependencies.networkMonitor.isConnected,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            rowHeight: rowHeight
        )
        return coordinator
    }
    
    private func makeTrackGroups() -> [MediaTrackGroup] {
        if let sections {
            return sections.map { section in
                MediaTrackGroup(
                    id: section.id,
                    title: section.title.isEmpty ? nil : section.title,
                    tracks: section.tracks,
                    isIndexable: !section.title.isEmpty
                )
            }
        }

        if groupByDisc {
            return groupTracksByDisc(tracks)
        }

        return [MediaTrackGroup(id: "all", title: nil, tracks: tracks, isIndexable: false)]
    }

    private func favoriteStateSignature(for tracks: [Track]) -> [Bool] {
        tracks.map { interactionModel.isFavorited($0) }
    }

    private func groupTracksByDisc(_ tracks: [Track]) -> [MediaTrackGroup] {
        let grouped = Dictionary(grouping: tracks) { $0.discNumber }
        let sortedKeys = grouped.keys.sorted()
        
        // Only show disc numbers if there are multiple discs
        let showDiscNumbers = sortedKeys.count > 1
        
        return sortedKeys.map { disc in
            let title = showDiscNumbers ? "Disc \(disc)" : nil
            return MediaTrackGroup(
                id: "disc-\(disc)",
                title: title,
                tracks: grouped[disc] ?? [],
                isIndexable: false
            )
        }
    }
    
    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate, UISearchResultsUpdating {
        var tracks: [Track]
        fileprivate var groupedTracks: [MediaTrackGroup]
        var groupSignature: [String]
        var favoriteStateSignature: [Bool]
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var showAlbumName: Bool
        var currentTrackId: String?
        var onTrackTap: (Track, Int) -> Void
        var onPlayNext: ((Track) -> Void)?
        var onPlayLast: ((Track) -> Void)?
        var onAddToPlaylist: ((Track) -> Void)?
        var onAddToRecentPlaylist: ((Track) -> Void)?
        var onToggleFavorite: ((Track) -> Void)?
        var onGoToAlbum: ((Track) -> Void)?
        var onGoToArtist: ((Track) -> Void)?
        var onGetInfo: ((Track) -> Void)?
        var onShareLink: ((Track) -> Void)?
        var onShareFile: ((Track) -> Void)?
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        var isTrackFavorited: ((Track) -> Bool)?
        var canAddToRecentPlaylist: ((Track) -> Bool)?
        var recentPlaylistTitle: String?
        var showsNativeSectionIndex: Bool
        var consumedSectionScrollRequestID: Int?
        var interactionModel: TrackRowInteractionModel
        var supplementalMetadataWidth: CGFloat?
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var settingsManager: SettingsManager
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var isOffline: Bool
        var activeDownloadTrackIdentities: Set<String>
        var rowHeight: CGFloat
        var lastAvailabilityGeneration: UInt64 = 0
        var lastDisplayRatingsRevision: UInt64 = 0
        /// Retains the UIHostingController used for the table header view
        var headerHostingController: UIHostingController<AnyView>?
        /// Retains the UIHostingController used for the table footer view
        var footerHostingController: UIHostingController<AnyView>?
        /// Pending search binding — set before the table is in a window, consumed
        /// once the UISearchController is attached to the navigation item.
        var pendingSearchBinding: Binding<String>?
        /// Reference to the table view for setContentScrollView
        weak var pendingTableView: UITableView?
        /// Retains the search controller so it isn't deallocated
        private var searchController: UISearchController?
        /// Active search binding for UISearchResultsUpdating
        private var activeSearchBinding: Binding<String>?

        fileprivate init(
            tracks: [Track],
            groupedTracks: [MediaTrackGroup],
            showArtwork: Bool,
            showTrackNumbers: Bool,
            showAlbumName: Bool,
            currentTrackId: String?,
            onTrackTap: @escaping (Track, Int) -> Void,
            onPlayNext: ((Track) -> Void)?,
            onPlayLast: ((Track) -> Void)?,
            onAddToPlaylist: ((Track) -> Void)?,
            onAddToRecentPlaylist: ((Track) -> Void)?,
            onToggleFavorite: ((Track) -> Void)?,
            onGoToAlbum: ((Track) -> Void)?,
            onGoToArtist: ((Track) -> Void)?,
            onGetInfo: ((Track) -> Void)?,
            onShareLink: ((Track) -> Void)?,
            onShareFile: ((Track) -> Void)?,
            onRemoveFromPlaylist: ((Track, Int) -> Void)?,
            isTrackFavorited: ((Track) -> Bool)?,
            canAddToRecentPlaylist: ((Track) -> Bool)?,
            recentPlaylistTitle: String?,
            showsNativeSectionIndex: Bool,
            interactionModel: TrackRowInteractionModel,
            supplementalMetadataWidth: CGFloat?,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            settingsManager: SettingsManager,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            isOffline: Bool,
            activeDownloadTrackIdentities: Set<String> = [],
            rowHeight: CGFloat
        ) {
            self.tracks = tracks
            self.groupedTracks = groupedTracks
            self.groupSignature = groupedTracks.map(\.signature)
            self.favoriteStateSignature = tracks.map { interactionModel.isFavorited($0) }
            self.showArtwork = showArtwork
            self.showTrackNumbers = showTrackNumbers
            self.showAlbumName = showAlbumName
            self.currentTrackId = currentTrackId
            self.onTrackTap = onTrackTap
            self.onPlayNext = onPlayNext
            self.onPlayLast = onPlayLast
            self.onAddToPlaylist = onAddToPlaylist
            self.onAddToRecentPlaylist = onAddToRecentPlaylist
            self.onToggleFavorite = onToggleFavorite
            self.onGoToAlbum = onGoToAlbum
            self.onGoToArtist = onGoToArtist
            self.onGetInfo = onGetInfo
            self.onShareLink = onShareLink
            self.onShareFile = onShareFile
            self.onRemoveFromPlaylist = onRemoveFromPlaylist
            self.isTrackFavorited = isTrackFavorited
            self.canAddToRecentPlaylist = canAddToRecentPlaylist
            self.recentPlaylistTitle = recentPlaylistTitle
            self.showsNativeSectionIndex = showsNativeSectionIndex
            self.interactionModel = interactionModel
            self.supplementalMetadataWidth = supplementalMetadataWidth
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.settingsManager = settingsManager
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.isOffline = isOffline
            self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
            self.rowHeight = rowHeight
        }
        
        // MARK: - Bounds-Safe Accessor

        /// Safely access a track, returning nil if indices are out of bounds.
        /// Protects against race conditions where UIKit requests cells for stale index paths
        /// after groupedTracks has been updated but before reloadData completes.
        private func track(at indexPath: IndexPath) -> Track? {
            indexedTrack(at: indexPath)?.track
        }

        private func indexedTrack(at indexPath: IndexPath) -> (track: Track, index: Int)? {
            guard indexPath.section < groupedTracks.count,
                  indexPath.row < groupedTracks[indexPath.section].tracks.count else {
                return nil
            }
            let index = groupedTracks[..<indexPath.section].reduce(0) { $0 + $1.tracks.count } + indexPath.row
            return (groupedTracks[indexPath.section].tracks[indexPath.row], index)
        }

        func sectionIndex(forID sectionID: String) -> Int? {
            groupedTracks.firstIndex { $0.id == sectionID }
        }

        public func numberOfSections(in tableView: UITableView) -> Int {
            groupedTracks.count
        }

        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard section < groupedTracks.count else { return 0 }
            return groupedTracks[section].tracks.count
        }

        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "TrackCell", for: indexPath) as! TrackTableViewCell
            cell.backgroundColor = .clear
            guard let track = track(at: indexPath) else { return cell }
            let isPlaying = track.playbackIdentity == currentTrackId
            cell.configure(
                with: track,
                showArtwork: showArtwork,
                showTrackNumber: showTrackNumbers,
                showAlbumName: showAlbumName,
                isPlaying: isPlaying,
                isUnavailableOffline: trackAvailabilityResolver.availability(for: track).shouldDim,
                isActivelyDownloading: activeDownloadTrackIdentities.contains(track.sourceScopedID),
                isFavorited: interactionModel.isFavorited(track),
                supplementalMetadataWidth: supplementalMetadataWidth,
                menu: makeDeferredContextMenu(for: track, at: indexPath),
                rowHeight: rowHeight,
                artworkLoader: artworkLoader
            )
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            return nil
        }
        
        public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            guard section < groupedTracks.count, let title = groupedTracks[section].title else { return nil }

            let headerView = UIView()
            headerView.backgroundColor = .clear

            let label = UILabel()
            label.text = title
            label.font = Self.sectionHeaderFont
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(EnsembleDesign.Color.secondaryText)
            label.translatesAutoresizingMaskIntoConstraints = false
            
            headerView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: headerView.leadingAnchor,
                    constant: EnsembleScaffold.BrowseSectionHeader.horizontalPadding
                ),
                label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                label.trailingAnchor.constraint(
                    equalTo: headerView.trailingAnchor,
                    constant: -EnsembleScaffold.BrowseSectionHeader.horizontalPadding
                )
            ])
            
            return headerView
        }
        
        public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            guard section < groupedTracks.count else { return 0 }
            return groupedTracks[section].title == nil ? 0 : Self.sectionHeaderHeight
        }

        private static var sectionHeaderFont: UIFont {
            UIFont.preferredFont(forTextStyle: .headline)
        }

        private static var sectionHeaderHeight: CGFloat {
            ceil(sectionHeaderFont.lineHeight + (EnsembleScaffold.BrowseSectionHeader.verticalPadding * 2))
        }

        public func sectionIndexTitles(for tableView: UITableView) -> [String]? {
            guard showsNativeSectionIndex else { return nil }

            let titles = groupedTracks.compactMap { group in
                group.isIndexable ? group.title : nil
            }
            return titles.isEmpty ? nil : titles
        }

        public func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
            if let section = groupedTracks.firstIndex(where: { $0.isIndexable && $0.title == title }) {
                return section
            }

            guard index >= 0, index < groupedTracks.count else {
                return NSNotFound
            }

            return index
        }

        public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
            return 0
        }

        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let indexed = indexedTrack(at: indexPath) else { return }
            let track = indexed.track

            let availability = trackAvailabilityResolver.availability(for: track)
            if !availability.canPlay {
                Task { @MainActor in
                    toastCenter.show(
                        ToastPayload(
                            style: .warning,
                            iconSystemName: "wifi.slash",
                            title: availability.userMessage ?? "Not available offline",
                            message: "Download this track before going offline.",
                            dedupeKey: "table-offline-track-blocked-\(track.sourceScopedID)"
                        )
                    )
                }
                return
            }

            onTrackTap(track, indexed.index)
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            rowHeight
        }

        public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let track = track(at: indexPath) else { return nil }
            let resolvedActions = interactionModel.resolve(for: track)
            guard let menu = makeContextMenu(for: track, at: indexPath, resolvedActions: resolvedActions) else { return nil }

            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                menu
            }
        }

        func makeContextMenu(
            for track: Track,
            at indexPath: IndexPath,
            resolvedActions: TrackRowInteractionModel.ResolvedActions
        ) -> UIMenu? {
            let indexed = indexedTrack(at: indexPath)
            return NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolvedActions,
                context: onRemoveFromPlaylist == nil ? .library : .playlistTrack(canRemove: true),
                onRemoveFromPlaylist: indexed.flatMap { indexed in
                    onRemoveFromPlaylist.map { callback in
                        { callback(indexed.track, indexed.index) }
                    }
                }
            )
        }

        func makeDeferredContextMenu(for track: Track, at indexPath: IndexPath) -> UIMenu? {
            guard interactionModel.hasContextMenu(for: track) || onRemoveFromPlaylist != nil else { return nil }

            return UIMenu(children: [
                UIDeferredMenuElement { [weak self] completion in
                    guard let self else {
                        completion([])
                        return
                    }

                    let resolvedActions = self.interactionModel.resolve(for: track)
                    let menu = self.makeContextMenu(for: track, at: indexPath, resolvedActions: resolvedActions)
                    completion(menu?.children ?? [])
                }
            ])
        }

        // MARK: - Drag Delegate (iPad drag-and-drop for media references)

        public func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard let track = track(at: indexPath) else { return [] }
            let provider = MediaDragPayload.trackItemProvider(for: track, shareService: shareService)
            let dragItem = UIDragItem(itemProvider: provider)
            dragItem.localObject = track
            return [dragItem]
        }

        // MARK: - Swipe Actions

        public func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let track = track(at: indexPath) else { return nil }
            let configured = settingsManager.trackSwipeLayout.leading
            let actions = swipeActions(from: configured, track: track)
            guard !actions.isEmpty else { return nil }

            let configuration = UISwipeActionsConfiguration(actions: actions)
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }

        public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
            guard let track = track(at: indexPath) else { return nil }
            let configured = settingsManager.trackSwipeLayout.trailing
            let actions = swipeActions(from: configured, track: track)
            guard !actions.isEmpty else { return nil }

            let configuration = UISwipeActionsConfiguration(actions: actions)
            configuration.performsFirstActionWithFullSwipe = true
            return configuration
        }

        private func swipeActions(from configured: [TrackSwipeAction?], track: Track) -> [UIContextualAction] {
            let resolvedActions = interactionModel.resolve(for: track)
            return configured.compactMap { candidate -> UIContextualAction? in
                guard let action = candidate,
                      TrackActionPresentation.isSupported(action, resolvedActions: resolvedActions) else { return nil }
                let contextual = UIContextualAction(
                    style: .normal,
                    title: TrackActionPresentation.title(for: action, resolvedActions: resolvedActions)
                ) { [weak self] _, _, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    if action == .favoriteToggle {
                        self.showFavoriteLoadingToast(for: track, willFavorite: !resolvedActions.isFavorited)
                    }
                    TrackActionPresentation.execute(action, track: track, resolvedActions: resolvedActions)
                    self.showSwipeConfirmation(for: action, track: track)
                    completion(true)
                }
                contextual.backgroundColor = UIColor(TrackActionPresentation.tint(for: action, resolvedActions: resolvedActions))
                contextual.image = UIImage(systemName: TrackActionPresentation.systemImage(for: action, resolvedActions: resolvedActions))
                return contextual
            }
        }

        private func showSwipeConfirmation(for action: TrackSwipeAction, track: Track) {
            guard let toast = TrackActionPresentation.confirmationToast(
                for: action,
                track: track,
                dedupeNamespace: "media-table"
            ) else { return }
            Task { @MainActor in
                toastCenter.show(toast)
            }
        }

        private func showFavoriteLoadingToast(for track: Track, willFavorite: Bool) {
            let toast = TrackActionPresentation.favoriteLoadingToast(
                for: track,
                willFavorite: willFavorite,
                dedupeNamespace: "media-table"
            )
            Task { @MainActor in
                toastCenter.show(toast)
            }
        }

        // MARK: - Search Controller

        /// Finds the hosting UIViewController and attaches a UISearchController to its
        /// navigation item. Uses setContentScrollView so the navigation controller
        /// knows which scroll view to observe for hide-on-scroll behavior.
        func attachSearchController() {
            guard let binding = pendingSearchBinding,
                  let tableView = pendingTableView else { return }

            // Walk up the responder chain to find the hosting UIViewController
            var responder: UIResponder? = tableView
            while let next = responder?.next {
                if let vc = next as? UIViewController, vc.navigationController != nil {
                    let sc = UISearchController(searchResultsController: nil)
                    sc.searchResultsUpdater = self
                    sc.obscuresBackgroundDuringPresentation = false
                    sc.searchBar.placeholder = "Search tracks"
                    sc.searchBar.text = binding.wrappedValue

                    vc.navigationItem.searchController = sc
                    vc.navigationItem.hidesSearchBarWhenScrolling = true
                    vc.definesPresentationContext = true

                    // Tell UIKit which scroll view to observe for hide-on-scroll.
                    // Without this, the navigation controller can't detect scrolling
                    // from a UIViewRepresentable's table view.
                    vc.setContentScrollView(tableView, for: .top)

                    searchController = sc
                    activeSearchBinding = binding
                    pendingSearchBinding = nil
                    pendingTableView = nil
                    return
                }
                responder = next
            }
        }

        public func updateSearchResults(for searchController: UISearchController) {
            activeSearchBinding?.wrappedValue = searchController.searchBar.text ?? ""
        }
    }
}
#endif
