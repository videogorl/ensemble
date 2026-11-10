import EnsembleDesignTokens
import EnsembleCore
import EnsembleSupport
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
    var defersLayoutUntilWindow = true
    var onLayout: (() -> Void)?

    #if DEBUG
    private let boundsSongsAutomationAccessibility: Bool = {
        let automation = AutomationLaunchOptions.current
        return automation.isEnabled && automation.startSurface == .songs
    }()

    // XCTest's full snapshot materializes offscreen native rows and exceeds the
    // SE's memory limit. Bound only Songs automation; derive rows after scrolling.
    private var songsAutomationElements: [Any] {
        var elements: [Any] = []
        if let tableHeaderView { elements.append(tableHeaderView) }
        elements.append(contentsOf: visibleCells)
        if let tableFooterView { elements.append(tableFooterView) }
        return elements
    }

    override var accessibilityElements: [Any]? {
        get { boundsSongsAutomationAccessibility ? songsAutomationElements : super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }

    override func accessibilityElementCount() -> Int {
        boundsSongsAutomationAccessibility ? songsAutomationElements.count : super.accessibilityElementCount()
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard boundsSongsAutomationAccessibility else { return super.accessibilityElement(at: index) }
        let elements = songsAutomationElements
        return elements.indices.contains(index) ? elements[index] : nil
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard boundsSongsAutomationAccessibility else { return super.index(ofAccessibilityElement: element) }
        return songsAutomationElements.firstIndex { ($0 as AnyObject) === (element as AnyObject) } ?? NSNotFound
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil && !hasAppearedInWindow {
            hasAppearedInWindow = true
            if defersLayoutUntilWindow {
                reloadData()
            }
            layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        // Skip layout passes before the table is in a window — these cause
        // unnecessary work and "layout outside view hierarchy" warnings.
        guard !defersLayoutUntilWindow || window != nil else { return }
        super.layoutSubviews()
        onLayout?()
    }
}

private final class HostedContentCell: UITableViewCell {
    static let reuseIdentifier = "HostedContentCell"

    func configure(content: AnyView, tableView: UITableView) {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        separatorInset = UIEdgeInsets(top: 0, left: tableView.bounds.width, bottom: 0, right: 0)

        contentConfiguration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)
    }
}

fileprivate struct MediaTrackGroup {
    let id: String
    let title: String?
    let tracks: [Track]

    var signature: String {
        "\(id)|\(title ?? "")|\(tracks.count)"
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
                artworkImageView.image = TrackArtworkThumbnailLoader.cachedImage(
                    for: track,
                    artworkLoader: artworkLoader
                )
                
                // Cancel any previous artwork load task
                artworkLoadTask?.cancel()
                
                artworkLoadTask = artworkImageView.image == nil ? Task { @MainActor in
                    let image = await TrackArtworkThumbnailLoader.image(
                        for: track,
                        artworkLoader: artworkLoader
                    ) {
                        self.currentTrackID == playbackIdentity
                    }

                    if self.currentTrackID == playbackIdentity {
                        self.artworkImageView.image = image
                    }
                } : nil
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

/// UIKit table behind `TrackListHost` on iOS and iPadOS.
struct MediaTrackList: UIViewRepresentable {
    let sections: [NativeTrackListSection]
    let configuration: NativeTrackListConfiguration
    /// Optional SwiftUI content embedded as the table's self-sizing first row.
    /// Scrolls with the rows while preserving cell recycling.
    let tableHeaderContent: AnyView?
    /// Changes when the header content changes without a structural change.
    let tableHeaderRevision: String?
    /// Optional SwiftUI content embedded as the table's last row, used for
    /// loading and empty states below the rows.
    let tableFooterContent: AnyView?
    let onRefresh: (() async -> Void)?
    let sectionScrollRequest: TrackSectionScrollRequest?
    let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    let onTrackTap: (Track, Int) -> Void
    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.trackListDisplayRatingsRevision) private var displayRatingsRevision

    init(
        sections: [NativeTrackListSection],
        configuration: NativeTrackListConfiguration,
        tableHeaderContent: AnyView?,
        tableHeaderRevision: String?,
        tableFooterContent: AnyView?,
        onRefresh: (() async -> Void)?,
        sectionScrollRequest: TrackSectionScrollRequest?,
        onRemoveFromPlaylist: ((Track, Int) -> Void)?,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = sections
        self.configuration = configuration
        self.tableHeaderContent = tableHeaderContent
        self.tableHeaderRevision = tableHeaderRevision
        self.tableFooterContent = tableFooterContent
        self.onRefresh = onRefresh
        self.sectionScrollRequest = sectionScrollRequest
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.onTrackTap = onTrackTap
    }

    /// Migration adapter for direct callers; removed once they use `TrackListHost`.
    init(
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
        bottomContentInset: CGFloat = 0,
        rowHeight: CGFloat = TrackListLayoutMetrics.defaultRowHeight,
        tableHeaderContent: AnyView? = nil,
        tableHeaderRevision: String? = nil,
        tableFooterContent: AnyView? = nil,
        interactionModel: TrackRowInteractionModel,
        supplementalMetadataWidth: CGFloat? = nil,
        trackSourceLabels: [String: String] = [:],
        onGoToArtist: ((Track) -> Void)? = nil,
        onRemoveFromPlaylist: ((Track, Int) -> Void)? = nil,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.init(
            sections: groupByDisc
                ? NativeTrackListSection.discSections(for: tracks)
                : [NativeTrackListSection(id: "all", title: "", tracks: tracks)],
            configuration: NativeTrackListConfiguration(
                showArtwork: showArtwork,
                showTrackNumbers: showTrackNumbers,
                showAlbumName: showAlbumName,
                managesOwnScrolling: managesOwnScrolling,
                rowHeight: rowHeight,
                bottomContentInset: bottomContentInset,
                supplementalMetadataWidth: supplementalMetadataWidth,
                trackSourceLabels: trackSourceLabels,
                currentTrackId: currentTrackId,
                selectedTrackId: selectedTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadTrackIdentities: activeDownloadTrackIdentities,
                interactionModel: interactionModel
            ),
            tableHeaderContent: tableHeaderContent,
            tableHeaderRevision: tableHeaderRevision,
            tableFooterContent: tableFooterContent,
            onRefresh: nil,
            sectionScrollRequest: nil,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    /// A single section keeps the caller's array storage, so unchanged
    /// updates skip the per-track comparison.
    private var tracks: [Track] {
        sections.count == 1 ? sections[0].tracks : sections.flatMap(\.tracks)
    }

    /// Without its own scrolling the table sits in a parent `ScrollView`:
    /// scrolling is disabled and layout waits for a window.
    private var managesOwnScrolling: Bool { configuration.managesOwnScrolling }

    public func makeUIView(context: Context) -> UITableView {
        let tableView = DeferredLayoutTableView(frame: .zero, style: .plain)
        tableView.defersLayoutUntilWindow = !managesOwnScrolling
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.register(TrackTableViewCell.self, forCellReuseIdentifier: "TrackCell")
        tableView.register(HostedContentCell.self, forCellReuseIdentifier: HostedContentCell.reuseIdentifier)
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: TrackListLayoutMetrics.contentLeadingInset(
                showArtwork: configuration.showArtwork,
                showTrackNumbers: configuration.showTrackNumbers
            ),
            bottom: 0,
            right: 0
        )
        tableView.separatorColor = TrackListLayoutMetrics.nativeSeparatorColor
        tableView.backgroundColor = .clear
        tableView.isScrollEnabled = managesOwnScrolling

        if managesOwnScrolling, onRefresh != nil {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                context.coordinator,
                action: #selector(Coordinator.refresh(_:)),
                for: .valueChanged
            )
            tableView.refreshControl = refreshControl
        }

        // Self-scrolling tables extend under the nav bar (via .ignoresSafeArea on the
        // SwiftUI side) and use .automatic so UIKit adds the correct top content inset.
        // This lets content scroll behind the translucent navigation bar.
        // Non-scrolling tables embedded in a parent ScrollView use .never.
        tableView.contentInsetAdjustmentBehavior = managesOwnScrolling ? .automatic : .never

        // Suppress any default section footer height so the content height stays
        // exactly N × rowHeight with no extra trailing space.
        tableView.sectionFooterHeight = 0

        // iOS 15 introduced automatic top padding above section headers; suppress it
        // so the content height is exactly N × rowHeight with no leading offset.
        tableView.sectionHeaderTopPadding = 0

        // Lets content scroll behind the mini player/tab bar with blur effect.
        if managesOwnScrolling && configuration.bottomContentInset > 0 {
            tableView.contentInset.bottom = configuration.bottomContentInset
        }

        // Enable drag-and-drop for downloaded tracks on iPad
        tableView.dragDelegate = context.coordinator
        tableView.dragInteractionEnabled = true
        context.coordinator.tableView = tableView
        tableView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.selectRequestedTrack()
        }
        return tableView
    }

    public func updateUIView(_ tableView: UITableView, context: Context) {
        let coordinator = context.coordinator
        let tracks = tracks
        let bottomContentInset = configuration.bottomContentInset
        coordinator.selectedTrackId = configuration.selectedTrackId
        if managesOwnScrolling,
           coordinator.contentScrollViewOwner == nil,
           tableView.window != nil {
            coordinator.registerContentScrollView(tableView)
        }

        // Re-apply content insets if they were cleared. This can happen when
        // .automatic contentInsetAdjustmentBehavior recalculates insets as the table
        // enters the view hierarchy (e.g. a navigation controller or tab bar controller).
        if managesOwnScrolling && tableView.contentInset.top != 0 {
            tableView.contentInset.top = 0
        }
        if managesOwnScrolling && bottomContentInset > 0 && tableView.contentInset.bottom != bottomContentInset {
            EnsembleLogger.debug("MediaTrackList re-applying bottomContentInset: was \(tableView.contentInset.bottom), setting to \(bottomContentInset)")
            tableView.contentInset.bottom = bottomContentInset
        }

        let contentIsUnchanged: Bool = if let contentRevision = configuration.contentRevision {
            contentRevision == coordinator.contentRevision
        } else {
            sectionsShareStorage(coordinator.sections, sections)
        }
        let newGroupedTracks = contentIsUnchanged ? coordinator.groupedTracks : makeTrackGroups()

        // Check if track list structure changed (additions/removals/reordering).
        // Shared array storage avoids repeating this linear scan on unrelated updates.
        let newGroupSignature = contentIsUnchanged ? coordinator.groupSignature : newGroupedTracks.map(\.signature)
        let trackState = contentIsUnchanged
            ? (identityOrderMatches: true, downloadStateChanged: false)
            : compareTrackListState(coordinator.tracks, tracks)
        let dataChanged = !trackState.identityOrderMatches ||
            coordinator.groupSignature != newGroupSignature ||
            (coordinator.tableHeaderContent == nil) != (tableHeaderContent == nil) ||
            coordinator.tableHeaderRevision != tableHeaderRevision ||
            (coordinator.tableFooterContent == nil) != (tableFooterContent == nil)

        // Check if any track's download state changed (localFilePath set or cleared)
        let downloadStateChanged = !dataChanged && trackState.downloadStateChanged

        let currentTrackChanged = coordinator.currentTrackId != configuration.currentTrackId
        // Read network state from DependencyContainer (not observed — parent drives re-renders)
        let isOffline = !dependencies.networkMonitor.isConnected
        let offlineStateChanged = coordinator.isOffline != isOffline
        let activeDownloadsChanged = coordinator.activeDownloadTrackIdentities != configuration.activeDownloadTrackIdentities
        let availabilityChanged = coordinator.lastAvailabilityGeneration != configuration.availabilityGeneration
        let supplementalMetadataWidthChanged = coordinator.supplementalMetadataWidth != configuration.supplementalMetadataWidth
        let trackSourceLabelsChanged = coordinator.trackSourceLabels != configuration.trackSourceLabels
        let displayRatingsChanged = coordinator.lastDisplayRatingsRevision != displayRatingsRevision
        let newFavoriteStateSignature = !dataChanged && displayRatingsChanged
            ? favoriteStateSignature(for: tracks)
            : coordinator.favoriteStateSignature
        let favoriteStateChanged = !dataChanged && coordinator.favoriteStateSignature != newFavoriteStateSignature

        let selectedRowIdentity = tableView.indexPathForSelectedRow
            .flatMap { coordinator.track(at: $0)?.playbackIdentity }

        // Update coordinator state
        coordinator.tracks = tracks
        coordinator.sections = sections
        coordinator.contentRevision = configuration.contentRevision
        coordinator.groupedTracks = newGroupedTracks
        coordinator.groupSignature = newGroupSignature
        coordinator.favoriteStateSignature = newFavoriteStateSignature
        coordinator.showArtwork = configuration.showArtwork
        coordinator.showTrackNumbers = configuration.showTrackNumbers
        coordinator.showAlbumName = configuration.showAlbumName
        coordinator.currentTrackId = configuration.currentTrackId
        coordinator.onTrackTap = onTrackTap
        coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        coordinator.interactionModel = configuration.interactionModel
        coordinator.supplementalMetadataWidth = configuration.supplementalMetadataWidth
        coordinator.trackSourceLabels = configuration.trackSourceLabels
        coordinator.artworkLoader = dependencies.artworkLoader
        coordinator.toastCenter = dependencies.toastCenter
        coordinator.settingsManager = dependencies.settingsManager
        coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        coordinator.isOffline = isOffline
        coordinator.activeDownloadTrackIdentities = configuration.activeDownloadTrackIdentities
        coordinator.rowHeight = configuration.rowHeight
        coordinator.lastAvailabilityGeneration = configuration.availabilityGeneration
        coordinator.lastDisplayRatingsRevision = displayRatingsRevision
        // Hosted cells are separate SwiftUI roots and do not inherit the environment.
        coordinator.tableHeaderContent = tableHeaderContent.map { AnyView($0.environment(dependencies)) }
        coordinator.tableHeaderRevision = tableHeaderRevision
        coordinator.tableFooterContent = tableFooterContent.map { AnyView($0.environment(dependencies)) }
        coordinator.onRefresh = onRefresh

        // Reload data immediately after updating groupedTracks to keep UIKit's geometry
        // in sync with the backing data. Previously there was a ~85 line gap between the
        // data assignment and reloadData(), during which delegate methods could fire with
        // stale index paths against the new (possibly shorter) data — causing crashes.
        if tableView.window != nil && dataChanged {
            tableView.reloadData()
            if let selectedRowIdentity,
               let indexPath = coordinator.indexPath(forTrackId: selectedRowIdentity) {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            }
        }

        if let tableFooterContent = coordinator.tableFooterContent,
           let footerCell = tableView.cellForRow(
               at: IndexPath(row: 0, section: coordinator.footerSection)
           ) as? HostedContentCell {
            footerCell.configure(content: tableFooterContent, tableView: tableView)
        }

        // Skip remaining work when the table isn't in a window yet — DeferredLayoutTableView
        // will trigger reloadData() on didMoveToWindow to avoid early layout passes.
        guard tableView.window != nil else { return }

        if let sectionScrollRequest,
           coordinator.consumedSectionScrollRequestID != sectionScrollRequest.id,
           let targetSection = coordinator.sectionIndex(forID: sectionScrollRequest.sectionID) {
            coordinator.consumedSectionScrollRequestID = sectionScrollRequest.id
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

        coordinator.selectRequestedTrack()

        if !dataChanged && (currentTrackChanged || offlineStateChanged || downloadStateChanged || activeDownloadsChanged || availabilityChanged || supplementalMetadataWidthChanged || trackSourceLabelsChanged || favoriteStateChanged) {
            // Reconfigure visible cells when track state or adaptive metadata width changes.
            // Bounds-check indexPaths since visible cells may reference stale geometry.
            tableView.visibleCells.forEach { cell in
                if let trackCell = cell as? TrackTableViewCell,
                   let indexPath = tableView.indexPath(for: cell),
                   let groupIndex = coordinator.groupIndex(forTableSection: indexPath.section),
                   indexPath.row < newGroupedTracks[groupIndex].tracks.count {
                    let track = newGroupedTracks[groupIndex].tracks[indexPath.row]
                    let isPlaying = track.playbackIdentity == configuration.currentTrackId
                    trackCell.configure(
                        with: track,
                        showArtwork: configuration.showArtwork,
                        showTrackNumber: configuration.showTrackNumbers,
                        showAlbumName: configuration.showAlbumName,
                        isPlaying: isPlaying,
                        isUnavailableOffline: coordinator.trackAvailabilityResolver.availability(for: track).shouldDim,
                        isActivelyDownloading: coordinator.activeDownloadTrackIdentities.contains(track.sourceScopedID),
                        isFavorited: coordinator.interactionModel.isFavorited(track),
                        supplementalMetadataWidth: coordinator.supplementalMetadataWidth,
                        sourceLabel: coordinator.sourceLabel(for: track),
                        menu: coordinator.makeDeferredContextMenu(for: track, at: indexPath),
                        rowHeight: coordinator.rowHeight,
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
            configuration: configuration,
            onTrackTap: onTrackTap,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            settingsManager: dependencies.settingsManager,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            isOffline: !dependencies.networkMonitor.isConnected,
            displayRatingsRevision: displayRatingsRevision,
            tableHeaderContent: tableHeaderContent.map { AnyView($0.environment(dependencies)) },
            tableHeaderRevision: tableHeaderRevision,
            tableFooterContent: tableFooterContent.map { AnyView($0.environment(dependencies)) },
            onRefresh: onRefresh
        )
        coordinator.observeArtworkRecovery(dependencies.libraryChanges)
        return coordinator
    }

    private func makeTrackGroups() -> [MediaTrackGroup] {
        sections.map { section in
            MediaTrackGroup(
                id: section.id,
                title: section.title.isEmpty ? nil : section.title,
                tracks: section.tracks
            )
        }
    }

    private func sectionsShareStorage(
        _ lhs: [NativeTrackListSection],
        _ rhs: [NativeTrackListSection]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { previous, current in
            previous.id == current.id
                && previous.title == current.title
                && arraysShareStorage(previous.tracks, current.tracks)
        }
    }

    private func favoriteStateSignature(for tracks: [Track]) -> [Bool] {
        tracks.map { configuration.interactionModel.isFavorited($0) }
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
        var sections: [NativeTrackListSection]
        var contentRevision: UInt64?
        var onTrackTap: (Track, Int) -> Void
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        var consumedSectionScrollRequestID: Int?
        var selectedTrackId: String?
        var consumedSelectedTrackId: String?
        var interactionModel: TrackRowInteractionModel
        var supplementalMetadataWidth: CGFloat?
        var trackSourceLabels: [String: String]
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
        var onRefresh: (() async -> Void)?
        weak var contentScrollViewOwner: UIViewController?
        weak var tableView: UITableView?
        private var artworkRecoveryObserver: StreamSubscription?

        fileprivate init(
            tracks: [Track],
            sections: [NativeTrackListSection],
            groupedTracks: [MediaTrackGroup],
            configuration: NativeTrackListConfiguration,
            onTrackTap: @escaping (Track, Int) -> Void,
            onRemoveFromPlaylist: ((Track, Int) -> Void)?,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            settingsManager: SettingsManager,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            isOffline: Bool,
            displayRatingsRevision: UInt64,
            tableHeaderContent: AnyView?,
            tableHeaderRevision: String?,
            tableFooterContent: AnyView?,
            onRefresh: (() async -> Void)?
        ) {
            self.tracks = tracks
            self.sections = sections
            self.contentRevision = configuration.contentRevision
            self.groupedTracks = groupedTracks
            self.groupSignature = groupedTracks.map(\.signature)
            self.favoriteStateSignature = []
            self.showArtwork = configuration.showArtwork
            self.showTrackNumbers = configuration.showTrackNumbers
            self.showAlbumName = configuration.showAlbumName
            self.currentTrackId = configuration.currentTrackId
            self.onTrackTap = onTrackTap
            self.onRemoveFromPlaylist = onRemoveFromPlaylist
            self.interactionModel = configuration.interactionModel
            self.supplementalMetadataWidth = configuration.supplementalMetadataWidth
            self.trackSourceLabels = configuration.trackSourceLabels
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.settingsManager = settingsManager
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.isOffline = isOffline
            self.activeDownloadTrackIdentities = configuration.activeDownloadTrackIdentities
            self.rowHeight = configuration.rowHeight
            self.lastDisplayRatingsRevision = displayRatingsRevision
            self.tableHeaderContent = tableHeaderContent
            self.tableHeaderRevision = tableHeaderRevision
            self.tableFooterContent = tableFooterContent
            self.onRefresh = onRefresh
            super.init()
        }

        func observeArtworkRecovery(_ libraryChanges: LibraryChanges) {
            artworkRecoveryObserver = libraryChanges.events([.artworkServersAvailable]).observe(self) { coordinator, _ in
                coordinator.retryFailedArtwork()
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

        @objc func refresh(_ refreshControl: UIRefreshControl) {
            guard let onRefresh else {
                refreshControl.endRefreshing()
                return
            }

            Task { @MainActor in
                await onRefresh()
                refreshControl.endRefreshing()
            }
        }
        
        // MARK: - Bounds-Safe Accessor

        /// Safely access a track, returning nil if indices are out of bounds.
        /// Protects against race conditions where UIKit requests cells for stale index paths
        /// after groupedTracks has been updated but before reloadData completes.
        fileprivate func track(at indexPath: IndexPath) -> Track? {
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

        // SwiftUI can supply the request before the table enters its window.
        // Consume it only once UIKit has laid out the destination's rows.
        func selectRequestedTrack() {
            guard let tableView, tableView.window != nil,
                  tableView.bounds.width > 0, tableView.bounds.height > 0,
                  let selectedTrackId, consumedSelectedTrackId != selectedTrackId,
                  let indexPath = indexPath(forTrackId: selectedTrackId),
                  indexPath.section < tableView.numberOfSections,
                  indexPath.row < tableView.numberOfRows(inSection: indexPath.section) else { return }
            consumedSelectedTrackId = selectedTrackId
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .middle)
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
                    : (tableView.superview?.bounds.width ?? 0)
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
            groupIndex(forTableSection: indexPath.section) == nil ? UITableView.automaticDimension : rowHeight
        }

        public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let track = track(at: indexPath) else { return nil }
            let resolvedActions = interactionModel.resolve(for: track, in: tracks)
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

                    let resolvedActions = self.interactionModel.resolve(for: track, in: self.tracks)
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
