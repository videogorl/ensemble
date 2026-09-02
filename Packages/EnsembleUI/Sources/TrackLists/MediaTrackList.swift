import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

func compareTrackListState(_ lhs: [Track], _ rhs: [Track]) -> (identityOrderMatches: Bool, downloadStateChanged: Bool) {
    guard lhs.count == rhs.count else { return (false, false) }

    var downloadStateChanged = false
    for (oldTrack, newTrack) in zip(lhs, rhs) {
        guard oldTrack.sourceScopedID == newTrack.sourceScopedID else { return (false, false) }
        downloadStateChanged = downloadStateChanged || oldTrack.isDownloaded != newTrack.isDownloaded
    }
    return (true, downloadStateChanged)
}

func arraysShareStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    guard !lhs.isEmpty else { return true }
    return lhs.withUnsafeBufferPointer { lhsBuffer in
        rhs.withUnsafeBufferPointer { rhsBuffer in
            lhsBuffer.baseAddress == rhsBuffer.baseAddress
        }
    }
}

func trackIdentityOrderMatches(_ lhs: [Track], _ rhs: [Track]) -> Bool {
    compareTrackListState(lhs, rhs).identityOrderMatches
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

private final class HostedContentController: UIHostingController<AnyView> {
    var onContentHeightChange: ((CGFloat) -> Void)?
    private var contentHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }

        let fittingHeight = view.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(contentHeight - fittingHeight) > 1 else { return }
        contentHeight = fittingHeight
        onContentHeightChange?(fittingHeight)
    }
}

private final class HostedContentCell: UITableViewCell {
    static let reuseIdentifier = "HostedContentCell"
    private var hostingController: HostedContentController?

    func configure(content: AnyView, tableView: UITableView) {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        separatorInset = UIEdgeInsets(top: 0, left: tableView.bounds.width, bottom: 0, right: 0)

        if #available(iOS 16.0, *) {
            hostingController?.view.removeFromSuperview()
            hostingController = nil
            contentConfiguration = UIHostingConfiguration {
                content
            }
            .margins(.all, 0)
            return
        }

        if let hostingController {
            hostingController.rootView = content
            return
        }

        let hostingController = HostedContentController(rootView: content)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        hostingController.onContentHeightChange = { [weak self, weak tableView] _ in
            guard self?.window != nil, let tableView else { return }
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
        self.hostingController = hostingController
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
        let selectedBackground = UIView()
        selectedBackground.backgroundColor = UIColor(EnsembleScaffold.BrowseSelection.fillColor)
        selectedBackgroundView = selectedBackground

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
        sourceLabel: String? = nil,
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
        if let unavailableReason = track.unavailableReason {
            subtitleParts.append(unavailableReason)
        }
        if let sourceLabel {
            subtitleParts.append(sourceLabel)
        }
        subtitleLabel.text = showsArtistMetadataColumn ? nil : subtitleParts.joined(separator: " · ")
        subtitleLabel.isHidden = showsArtistMetadataColumn
        let artistMetadata = track.unavailableReason ?? track.artistName ?? "Unknown Artist"
        artistMetadataLabel.text = [artistMetadata, sourceLabel].compactMap { $0 }.joined(separator: " · ")
        albumMetadataLabel.text = track.unavailableReason == nil ? track.albumName ?? "Unknown Album" : ""
        
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

    func prepareArtworkRetry() -> Bool {
        guard artworkImageView.image == nil else { return false }
        currentTrackID = nil
        return true
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
    let selectedTrackId: String?
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
    let trackSourceLabels: [String: String]
    let scrollOffset: Binding<CGFloat>?

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
    /// Optional SwiftUI content to embed as the table's self-sizing first row.
    /// Scrolls naturally with the table while preserving full cell recycling.
    /// Used by MediaDetailView to scroll album art + action buttons with the track list.
    let tableHeaderContent: AnyView?
    let tableHeaderRevision: String?
    /// Optional SwiftUI content to embed as the UITableView's `tableFooterView`.
    /// Used to show loading/empty indicators below the track list while keeping
    /// the header (chips + artwork + buttons) structurally identical across all states.
    let tableFooterContent: AnyView?
    @Environment(\.dependencies) private var dependencies
    @Environment(\.trackListDisplayRatingsRevision) private var displayRatingsRevision
    @Environment(\.scenePhase) private var scenePhase

    public init(
        tracks: [Track],
        showArtwork: Bool = true,
        showTrackNumbers: Bool = false,
        showAlbumName: Bool = true,
        groupByDisc: Bool = false,
        currentTrackId: String? = nil,
        selectedTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        managesOwnScrolling: Bool = false,
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        tableHeaderContent: AnyView? = nil,
        tableHeaderRevision: String? = nil,
        tableFooterContent: AnyView? = nil,
        interactionModel: TrackRowInteractionModel? = nil,
        supplementalMetadataWidth: CGFloat? = nil,
        trackSourceLabels: [String: String] = [:],
        scrollOffset: Binding<CGFloat>? = nil,
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
        self.selectedTrackId = selectedTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.managesOwnScrolling = managesOwnScrolling
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.rowHeight = rowHeight
        self.tableHeaderContent = tableHeaderContent
        self.tableHeaderRevision = tableHeaderRevision
        self.tableFooterContent = tableFooterContent
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.trackSourceLabels = trackSourceLabels
        self.scrollOffset = scrollOffset
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
        selectedTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadTrackIdentities: Set<String> = [],
        topContentInset: CGFloat = 0,
        bottomContentInset: CGFloat = 0,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        tableHeaderContent: AnyView? = nil,
        tableHeaderRevision: String? = nil,
        tableFooterContent: AnyView? = nil,
        interactionModel: TrackRowInteractionModel? = nil,
        supplementalMetadataWidth: CGFloat? = nil,
        trackSourceLabels: [String: String] = [:],
        scrollOffset: Binding<CGFloat>? = nil,
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
        self.selectedTrackId = selectedTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        self.managesOwnScrolling = true
        self.topContentInset = topContentInset
        self.bottomContentInset = bottomContentInset
        self.rowHeight = rowHeight
        self.tableHeaderContent = tableHeaderContent
        self.tableHeaderRevision = tableHeaderRevision
        self.tableFooterContent = tableFooterContent
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.trackSourceLabels = trackSourceLabels
        self.scrollOffset = scrollOffset
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
        tableView.register(HostedContentCell.self, forCellReuseIdentifier: HostedContentCell.reuseIdentifier)
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
        context.coordinator.tableView = tableView

        return tableView
    }
    
    public func updateUIView(_ tableView: UITableView, context: Context) {
        if context.coordinator.isSceneActive && scenePhase != .active {
            context.coordinator.persistScrollOffset()
        }
        context.coordinator.scrollOffset = scrollOffset
        context.coordinator.isSceneActive = scenePhase == .active

        if managesOwnScrolling,
           context.coordinator.contentScrollViewOwner == nil,
           tableView.window != nil {
            context.coordinator.registerContentScrollView(tableView)
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

        let contentIsUnchanged: Bool
        switch (context.coordinator.sections, sections) {
        case let (.some(previous), .some(current)):
            contentIsUnchanged = arraysShareStorage(previous, current)
        case (nil, nil):
            contentIsUnchanged = arraysShareStorage(context.coordinator.tracks, tracks)
        default:
            contentIsUnchanged = false
        }
        let newGroupedTracks = contentIsUnchanged ? context.coordinator.groupedTracks : makeTrackGroups()

        // Check if track list structure changed (additions/removals/reordering).
        // Shared array storage avoids repeating this linear scan on unrelated updates.
        let newGroupSignature = contentIsUnchanged ? context.coordinator.groupSignature : newGroupedTracks.map(\.signature)
        let trackState = contentIsUnchanged
            ? (identityOrderMatches: true, downloadStateChanged: false)
            : compareTrackListState(context.coordinator.tracks, tracks)
        let dataChanged = !trackState.identityOrderMatches ||
            context.coordinator.groupSignature != newGroupSignature ||
            (context.coordinator.tableHeaderContent == nil) != (tableHeaderContent == nil) ||
            context.coordinator.tableHeaderRevision != tableHeaderRevision ||
            (context.coordinator.tableFooterContent == nil) != (tableFooterContent == nil)

        // Check if any track's download state changed (localFilePath set or cleared)
        let downloadStateChanged = !dataChanged && trackState.downloadStateChanged

        let currentTrackChanged = context.coordinator.currentTrackId != currentTrackId
        // Read network state from DependencyContainer (not observed — parent drives re-renders)
        let isOffline = !dependencies.networkMonitor.isConnected
        let offlineStateChanged = context.coordinator.isOffline != isOffline
        let activeDownloadsChanged = context.coordinator.activeDownloadTrackIdentities != activeDownloadTrackIdentities
        let availabilityChanged = context.coordinator.lastAvailabilityGeneration != availabilityGeneration
        let supplementalMetadataWidthChanged = context.coordinator.supplementalMetadataWidth != supplementalMetadataWidth
        let trackSourceLabelsChanged = context.coordinator.trackSourceLabels != trackSourceLabels
        let displayRatingsChanged = context.coordinator.lastDisplayRatingsRevision != displayRatingsRevision
        let newFavoriteStateSignature = !dataChanged && displayRatingsChanged
            ? favoriteStateSignature(for: tracks)
            : context.coordinator.favoriteStateSignature
        let favoriteStateChanged = !dataChanged && context.coordinator.favoriteStateSignature != newFavoriteStateSignature

        // Update coordinator state
        context.coordinator.tracks = tracks
        context.coordinator.sections = sections
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
        context.coordinator.trackSourceLabels = trackSourceLabels
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.settingsManager = dependencies.settingsManager
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.isOffline = isOffline
        context.coordinator.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        context.coordinator.rowHeight = rowHeight
        context.coordinator.lastAvailabilityGeneration = availabilityGeneration
        context.coordinator.lastDisplayRatingsRevision = displayRatingsRevision
        context.coordinator.tableHeaderContent = tableHeaderContent
        context.coordinator.tableHeaderRevision = tableHeaderRevision
        context.coordinator.tableFooterContent = tableFooterContent

        // Reload data immediately after updating groupedTracks to keep UIKit's geometry
        // in sync with the backing data. Previously there was a ~85 line gap between the
        // data assignment and reloadData(), during which delegate methods could fire with
        // stale index paths against the new (possibly shorter) data — causing crashes.
        if tableView.window != nil && dataChanged {
            tableView.reloadData()
            tableView.reloadSectionIndexTitles()
        }

        if let tableFooterContent,
           let footerCell = tableView.cellForRow(
               at: IndexPath(row: 0, section: context.coordinator.footerSection)
           ) as? HostedContentCell {
            footerCell.configure(content: tableFooterContent, tableView: tableView)
        }

        // Skip remaining work when the table isn't in a window yet — DeferredLayoutTableView
        // will trigger reloadData() on didMoveToWindow to avoid early layout passes.
        guard tableView.window != nil else { return }

        if !context.coordinator.didRestoreScrollOffset {
            if let scrollOffset {
                tableView.layoutIfNeeded()
                let maximumOffset = max(
                    tableView.contentSize.height - tableView.bounds.height
                        + tableView.adjustedContentInset.top + tableView.adjustedContentInset.bottom,
                    0
                )
                let targetOffset = SceneScrollRestoration.clampedOffset(
                    scrollOffset.wrappedValue,
                    maximumOffset: maximumOffset
                ) - tableView.adjustedContentInset.top
                tableView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
            }
            context.coordinator.didRestoreScrollOffset = true
        }

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

        if let selectedTrackId,
           context.coordinator.consumedSelectedTrackId != selectedTrackId,
           let indexPath = context.coordinator.indexPath(forTrackId: selectedTrackId) {
            context.coordinator.consumedSelectedTrackId = selectedTrackId
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .middle)
        }

        if !dataChanged && (currentTrackChanged || offlineStateChanged || downloadStateChanged || activeDownloadsChanged || availabilityChanged || supplementalMetadataWidthChanged || trackSourceLabelsChanged || favoriteStateChanged) {
            // Reconfigure visible cells when track state or adaptive metadata width changes.
            // Bounds-check indexPaths since visible cells may reference stale geometry.
            tableView.visibleCells.forEach { cell in
                if let trackCell = cell as? TrackTableViewCell,
                   let indexPath = tableView.indexPath(for: cell),
                   let groupIndex = context.coordinator.groupIndex(forTableSection: indexPath.section),
                   indexPath.row < newGroupedTracks[groupIndex].tracks.count {
                    let track = newGroupedTracks[groupIndex].tracks[indexPath.row]
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
                        sourceLabel: context.coordinator.sourceLabel(for: track),
                        menu: context.coordinator.makeDeferredContextMenu(for: track, at: indexPath),
                        rowHeight: context.coordinator.rowHeight,
                        artworkLoader: dependencies.artworkLoader
                    )
                }
            }
        }
    }

    public static func dismantleUIView(_ tableView: UITableView, coordinator: Coordinator) {
        coordinator.unregisterContentScrollView(tableView)
    }
    
    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            tracks: tracks,
            sections: sections,
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
            trackSourceLabels: trackSourceLabels,
            scrollOffset: scrollOffset,
            isSceneActive: scenePhase == .active,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            settingsManager: dependencies.settingsManager,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            isOffline: !dependencies.networkMonitor.isConnected,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            rowHeight: rowHeight,
            displayRatingsRevision: displayRatingsRevision,
            tableHeaderContent: tableHeaderContent,
            tableHeaderRevision: tableHeaderRevision,
            tableFooterContent: tableFooterContent
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
    
    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate {
        var tracks: [Track]
        fileprivate var groupedTracks: [MediaTrackGroup]
        var groupSignature: [String]
        var favoriteStateSignature: [Bool]
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var showAlbumName: Bool
        var currentTrackId: String?
        var sections: [NativeTrackListSection]?
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
        var consumedSelectedTrackId: String?
        var interactionModel: TrackRowInteractionModel
        var supplementalMetadataWidth: CGFloat?
        var trackSourceLabels: [String: String]
        var scrollOffset: Binding<CGFloat>?
        var pendingScrollOffset: CGFloat?
        var isSceneActive: Bool
        var didRestoreScrollOffset = false
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var settingsManager: SettingsManager
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var isOffline: Bool
        var activeDownloadTrackIdentities: Set<String>
        var rowHeight: CGFloat
        var tableFooterContent: AnyView?
        var lastAvailabilityGeneration: UInt64 = 0
        var lastDisplayRatingsRevision: UInt64 = 0
        var tableHeaderContent: AnyView?
        var tableHeaderRevision: String?
        weak var contentScrollViewOwner: UIViewController?
        weak var tableView: UITableView?
        private var artworkRecoveryObserver: NSObjectProtocol?

        fileprivate init(
            tracks: [Track],
            sections: [NativeTrackListSection]?,
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
            trackSourceLabels: [String: String],
            scrollOffset: Binding<CGFloat>?,
            isSceneActive: Bool,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            settingsManager: SettingsManager,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            isOffline: Bool,
            activeDownloadTrackIdentities: Set<String> = [],
            rowHeight: CGFloat,
            displayRatingsRevision: UInt64,
            tableHeaderContent: AnyView?,
            tableHeaderRevision: String?,
            tableFooterContent: AnyView?
        ) {
            self.tracks = tracks
            self.sections = sections
            self.groupedTracks = groupedTracks
            self.groupSignature = groupedTracks.map(\.signature)
            self.favoriteStateSignature = []
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
            self.trackSourceLabels = trackSourceLabels
            self.scrollOffset = scrollOffset
            self.isSceneActive = isSceneActive
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.settingsManager = settingsManager
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.isOffline = isOffline
            self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
            self.rowHeight = rowHeight
            self.lastDisplayRatingsRevision = displayRatingsRevision
            self.tableHeaderContent = tableHeaderContent
            self.tableHeaderRevision = tableHeaderRevision
            self.tableFooterContent = tableFooterContent
            super.init()
            artworkRecoveryObserver = NotificationCenter.default.addObserver(
                forName: ArtworkLoader.serversBecameAvailable,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.retryFailedArtwork()
            }
        }

        deinit {
            if let artworkRecoveryObserver {
                NotificationCenter.default.removeObserver(artworkRecoveryObserver)
            }
        }

        private func retryFailedArtwork() {
            guard let tableView else { return }
            let indexPaths = tableView.visibleCells.compactMap { cell -> IndexPath? in
                guard let cell = cell as? TrackTableViewCell,
                      cell.prepareArtworkRetry() else { return nil }
                return tableView.indexPath(for: cell)
            }
            guard !indexPaths.isEmpty else { return }
            tableView.reloadRows(at: indexPaths, with: .none)
        }
        
        // MARK: - Bounds-Safe Accessor

        /// Safely access a track, returning nil if indices are out of bounds.
        /// Protects against race conditions where UIKit requests cells for stale index paths
        /// after groupedTracks has been updated but before reloadData completes.
        private func track(at indexPath: IndexPath) -> Track? {
            indexedTrack(at: indexPath)?.track
        }

        func sourceLabel(for track: Track) -> String? {
            track.sourceCompositeKey.flatMap { trackSourceLabels[$0] }
        }

        private func indexedTrack(at indexPath: IndexPath) -> (track: Track, index: Int)? {
            guard let groupIndex = groupIndex(forTableSection: indexPath.section),
                  indexPath.row < groupedTracks[groupIndex].tracks.count else {
                return nil
            }
            let index = groupedTracks[..<groupIndex].reduce(0) { $0 + $1.tracks.count } + indexPath.row
            return (groupedTracks[groupIndex].tracks[indexPath.row], index)
        }

        private var headerSectionCount: Int {
            tableHeaderContent == nil ? 0 : 1
        }

        var footerSection: Int {
            headerSectionCount + groupedTracks.count
        }

        fileprivate func groupIndex(forTableSection section: Int) -> Int? {
            let groupIndex = section - headerSectionCount
            return groupedTracks.indices.contains(groupIndex) ? groupIndex : nil
        }

        private func tableSection(forGroupIndex groupIndex: Int) -> Int {
            headerSectionCount + groupIndex
        }

        func sectionIndex(forID sectionID: String) -> Int? {
            groupedTracks.firstIndex { $0.id == sectionID }.map(tableSection(forGroupIndex:))
        }

        func indexPath(forTrackId id: String) -> IndexPath? {
            for (section, group) in groupedTracks.enumerated() {
                if let row = group.tracks.firstIndex(where: { $0.playbackIdentity == id }) {
                    return IndexPath(row: row, section: tableSection(forGroupIndex: section))
                }
            }
            return nil
        }

        public func numberOfSections(in tableView: UITableView) -> Int {
            footerSection + (tableFooterContent == nil ? 0 : 1)
        }

        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            if tableHeaderContent != nil, section == 0 {
                return 1
            }
            if section == footerSection {
                return tableFooterContent == nil ? 0 : 1
            }
            guard let groupIndex = groupIndex(forTableSection: section) else { return 0 }
            return groupedTracks[groupIndex].tracks.count
        }

        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            if tableHeaderContent != nil, indexPath.section == 0, let tableHeaderContent {
                let targetWidth = tableView.bounds.width > 1
                    ? tableView.bounds.width
                    : UIScreen.main.bounds.width
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: HostedContentCell.reuseIdentifier,
                    for: indexPath
                ) as! HostedContentCell
                cell.configure(
                    content: AnyView(tableHeaderContent.nativeTrackListHeaderWidth(targetWidth)),
                    tableView: tableView
                )
                return cell
            }

            if indexPath.section == footerSection, let tableFooterContent {
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: HostedContentCell.reuseIdentifier,
                    for: indexPath
                ) as! HostedContentCell
                cell.configure(content: tableFooterContent, tableView: tableView)
                return cell
            }

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
                sourceLabel: sourceLabel(for: track),
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
            guard let groupIndex = groupIndex(forTableSection: section),
                  let title = groupedTracks[groupIndex].title else { return nil }

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
            guard let groupIndex = groupIndex(forTableSection: section) else { return 0 }
            return groupedTracks[groupIndex].title == nil ? 0 : Self.sectionHeaderHeight
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
                return tableSection(forGroupIndex: section)
            }

            guard index >= 0, index < groupedTracks.count else {
                return NSNotFound
            }

            return tableSection(forGroupIndex: index)
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

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard didRestoreScrollOffset, isSceneActive, scrollOffset != nil else { return }
            pendingScrollOffset = max(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, 0)
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { persistScrollOffset() }
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            persistScrollOffset()
        }

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            persistScrollOffset()
        }

        func persistScrollOffset() {
            guard let pendingScrollOffset, let scrollOffset,
                  abs(scrollOffset.wrappedValue - pendingScrollOffset) > 0.5 else { return }
            scrollOffset.wrappedValue = pendingScrollOffset
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            groupIndex(forTableSection: indexPath.section) == nil ? UITableView.automaticDimension : rowHeight
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
            let canRemove = interactionModel.allowsRemovalFromPlaylist(track)
            return NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolvedActions,
                context: onRemoveFromPlaylist == nil ? .library : .playlistTrack(canRemove: canRemove),
                onRemoveFromPlaylist: canRemove ? indexed.flatMap { indexed in
                    onRemoveFromPlaylist.map { callback in
                        { callback(indexed.track, indexed.index) }
                    }
                } : nil
            )
        }

        func makeDeferredContextMenu(for track: Track, at indexPath: IndexPath) -> UIMenu? {
            guard interactionModel.hasContextMenu(for: track) || onRemoveFromPlaylist != nil else { return nil }

            return UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
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
            guard track.isLibraryAvailable else { return [] }
            let isFavorited = interactionModel.isFavorited(track)
            return configured.compactMap { candidate -> UIContextualAction? in
                guard let action = candidate, interactionModel.hasHandler(for: action) else { return nil }
                let contextual = UIContextualAction(
                    style: .normal,
                    title: TrackActionPresentation.title(for: action, isFavorited: isFavorited)
                ) { [weak self] _, _, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    let resolvedActions = self.interactionModel.resolve(for: track)
                    guard TrackActionPresentation.isSupported(action, resolvedActions: resolvedActions) else {
                        completion(false)
                        return
                    }
                    if action == .favoriteToggle {
                        self.showFavoriteLoadingToast(for: track, willFavorite: !resolvedActions.isFavorited)
                    }
                    TrackActionPresentation.execute(action, resolvedActions: resolvedActions)
                    self.showSwipeConfirmation(for: action, track: track)
                    completion(true)
                }
                contextual.backgroundColor = UIColor(TrackActionPresentation.tint(for: action, isFavorited: isFavorited))
                contextual.image = UIImage(systemName: TrackActionPresentation.systemImage(for: action, isFavorited: isFavorited))
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

        // MARK: - Navigation Content Scroll View

        func registerContentScrollView(_ tableView: UITableView) {
            var responder: UIResponder? = tableView
            while let next = responder?.next {
                if let vc = next as? UIViewController, vc.navigationController != nil {
                    vc.setContentScrollView(tableView, for: .top)
                    contentScrollViewOwner = vc
                    return
                }
                responder = next
            }
        }

        func unregisterContentScrollView(_ tableView: UITableView) {
            guard let contentScrollViewOwner else { return }
            if contentScrollViewOwner.contentScrollView(for: .top) === tableView {
                contentScrollViewOwner.setContentScrollView(nil, for: .top)
            }
            self.contentScrollViewOwner = nil
        }
    }
}
#endif
