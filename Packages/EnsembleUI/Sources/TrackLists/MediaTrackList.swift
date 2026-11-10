import EnsembleDesignTokens
import EnsembleCore
import EnsembleSupport
import SwiftUI

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
    
    func configure(
        with track: Track,
        content: TrackRowContent,
        menu: UIMenu?,
        rowHeight: CGFloat,
        artworkLoader: ArtworkLoaderProtocol
    ) {
        applyLayoutMetrics(for: rowHeight)
        titleLabel.text = content.title
        overflowButton.menu = menu
        overflowButton.isHidden = menu == nil

        // Show/hide favorite heart (positioned in existing margin, no content shift)
        favoriteHeartView.isHidden = !content.isFavorited

        // Remove old constraints
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false

        // Configure leading constraint based on what's showing
        let showArtwork = content.showsArtwork
        let showTrackNumber = content.showsTrackNumber
        let leadingAnchor = showArtwork ? artworkImageView.trailingAnchor : (showTrackNumber ? trackNumberLabel.trailingAnchor : contentView.leadingAnchor)
        let constant: CGFloat = showArtwork || showTrackNumber
            ? TrackListLayoutMetrics.rowInterItemSpacing
            : TrackListLayoutMetrics.rowHorizontalPadding

        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        subtitleLeadingConstraint = subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)

        titleLeadingConstraint?.isActive = true
        subtitleLeadingConstraint?.isActive = true

        applySupplementalMetadataLayout(artistWidth: content.artistColumnWidth, albumWidth: content.albumColumnWidth)

        let showsArtistMetadataColumn = content.artistColumnWidth != nil
        subtitleLabel.text = showsArtistMetadataColumn ? nil : content.subtitle
        subtitleLabel.isHidden = showsArtistMetadataColumn
        artistMetadataLabel.text = content.artistColumn
        albumMetadataLabel.text = content.albumColumn

        durationLabel.text = content.duration
        durationLabel.isHidden = content.isPlaying
        playingIndicator.isHidden = !content.isPlaying

        // Show spinner while downloading, download icon when complete, hide both otherwise
        downloadIcon.isHidden = content.downloadState != .downloaded
        if content.downloadState == .downloading {
            downloadSpinner.startAnimating()
        } else {
            downloadSpinner.stopAnimating()
        }

        artworkImageView.isHidden = !showArtwork
        trackNumberLabel.isHidden = !showTrackNumber
        if showTrackNumber {
            trackNumberLabel.text = content.trackNumber
        }

        contentView.alpha = content.isDimmed ? 0.45 : 1

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

    private func applySupplementalMetadataLayout(artistWidth: CGFloat?, albumWidth: CGFloat?) {
        let showsArtistColumn = artistWidth != nil
        let showsAlbumColumn = albumWidth != nil
        artistMetadataLabel.isHidden = !showsArtistColumn
        albumMetadataLabel.isHidden = !showsAlbumColumn
        artistWidthConstraint?.constant = artistWidth ?? 0
        albumWidthConstraint?.constant = albumWidth ?? 0

        titleTopConstraint?.isActive = !showsArtistColumn
        titleCenterYConstraint?.isActive = showsArtistColumn
        titleTrailingToDownloadConstraint?.isActive = !showsArtistColumn
        titleTrailingToArtistConstraint?.isActive = showsArtistColumn
        artistTrailingToAlbumConstraint?.isActive = showsArtistColumn && showsAlbumColumn
        artistTrailingToDownloadConstraint?.isActive = showsArtistColumn && !showsAlbumColumn
        albumTrailingToDownloadConstraint?.isActive = showsAlbumColumn
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
        let bottomContentInset = configuration.bottomContentInset
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

        let newState = makeState()
        let change = TrackListChange.between(coordinator.state, newState)
        let selectedRowIdentity = tableView.indexPathForSelectedRow
            .flatMap { coordinator.track(at: $0)?.playbackIdentity }

        // Update coordinator state
        coordinator.state = newState
        coordinator.configuration = configuration
        coordinator.onTrackTap = onTrackTap
        coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        coordinator.artworkLoader = dependencies.artworkLoader
        coordinator.toastCenter = dependencies.toastCenter
        coordinator.settingsManager = dependencies.settingsManager
        coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        // Hosted cells are separate SwiftUI roots and do not inherit the environment.
        coordinator.tableHeaderContent = tableHeaderContent.map { AnyView($0.environment(dependencies)) }
        coordinator.tableFooterContent = tableFooterContent.map { AnyView($0.environment(dependencies)) }
        coordinator.onRefresh = onRefresh

        // Reload data immediately after updating the rows to keep UIKit's geometry
        // in sync with the backing data. Previously there was a ~85 line gap between the
        // data assignment and reloadData(), during which delegate methods could fire with
        // stale index paths against the new (possibly shorter) data — causing crashes.
        if tableView.window != nil && change == .reload {
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

        if change == .reconfigureVisibleRows {
            // Bounds-checked: visible cells may reference stale geometry.
            tableView.visibleCells.forEach { cell in
                if let trackCell = cell as? TrackTableViewCell,
                   let indexPath = tableView.indexPath(for: cell),
                   let track = coordinator.track(at: indexPath) {
                    coordinator.configure(trackCell, with: track, at: indexPath)
                }
            }
        }
    }

    public static func dismantleUIView(_ tableView: UITableView, coordinator: Coordinator) {
        coordinator.unregisterContentScrollView(tableView)
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(
            state: makeState(),
            configuration: configuration,
            onTrackTap: onTrackTap,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            settingsManager: dependencies.settingsManager,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            tableHeaderContent: tableHeaderContent.map { AnyView($0.environment(dependencies)) },
            tableFooterContent: tableFooterContent.map { AnyView($0.environment(dependencies)) },
            onRefresh: onRefresh
        )
        coordinator.observeArtworkRecovery(dependencies.libraryChanges)
        return coordinator
    }

    private func makeState() -> TrackListChange.State {
        TrackListChange.State(
            rows: TrackListRows(sections: sections),
            contentRevision: configuration.contentRevision,
            hasHeader: tableHeaderContent != nil,
            headerRevision: tableHeaderRevision,
            hasFooter: tableFooterContent != nil,
            // Network state is read, not observed: the parent drives updates.
            rowState: TrackListChange.RowState(
                configuration: configuration,
                isOffline: !dependencies.networkMonitor.isConnected,
                displayRatingsRevision: displayRatingsRevision
            )
        )
    }

    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate {
        var state: TrackListChange.State
        var configuration: NativeTrackListConfiguration
        var onTrackTap: (Track, Int) -> Void
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        var consumedSectionScrollRequestID: Int?
        var consumedSelectedTrackId: String?
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var settingsManager: SettingsManager
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var tableFooterContent: AnyView?
        var tableHeaderContent: AnyView?
        var onRefresh: (() async -> Void)?
        weak var contentScrollViewOwner: UIViewController?
        weak var tableView: UITableView?
        private var artworkRecoveryObserver: StreamSubscription?

        fileprivate init(
            state: TrackListChange.State,
            configuration: NativeTrackListConfiguration,
            onTrackTap: @escaping (Track, Int) -> Void,
            onRemoveFromPlaylist: ((Track, Int) -> Void)?,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            settingsManager: SettingsManager,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            tableHeaderContent: AnyView?,
            tableFooterContent: AnyView?,
            onRefresh: (() async -> Void)?
        ) {
            self.state = state
            self.configuration = configuration
            self.onTrackTap = onTrackTap
            self.onRemoveFromPlaylist = onRemoveFromPlaylist
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.settingsManager = settingsManager
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.tableHeaderContent = tableHeaderContent
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

        private var rows: TrackListRows { state.rows }

        /// Nil for an index path UIKit still holds from before an update.
        fileprivate func track(at indexPath: IndexPath) -> Track? {
            indexedTrack(at: indexPath)?.track
        }

        func configure(_ cell: TrackTableViewCell, with track: Track, at indexPath: IndexPath) {
            cell.configure(
                with: track,
                content: TrackRowContent(
                    track: track,
                    configuration: configuration,
                    isDimmed: trackAvailabilityResolver.availability(for: track).shouldDim
                ),
                menu: makeDeferredContextMenu(for: track, at: indexPath),
                rowHeight: configuration.rowHeight,
                artworkLoader: artworkLoader
            )
        }

        private func indexedTrack(at indexPath: IndexPath) -> (track: Track, index: Int)? {
            rows.track(section: indexPath.section - headerSectionCount, row: indexPath.row)
        }

        private var headerSectionCount: Int {
            tableHeaderContent == nil ? 0 : 1
        }

        var footerSection: Int {
            headerSectionCount + rows.sections.count
        }

        /// The row-model section shown in a table section, if any.
        private func rowSection(forTableSection section: Int) -> NativeTrackListSection? {
            let index = section - headerSectionCount
            return rows.sections.indices.contains(index) ? rows.sections[index] : nil
        }

        func sectionIndex(forID sectionID: String) -> Int? {
            rows.section(withID: sectionID).map { $0 + headerSectionCount }
        }

        // SwiftUI can supply the request before the table enters its window.
        // Consume it only once UIKit has laid out the destination's rows.
        func selectRequestedTrack() {
            guard let tableView, tableView.window != nil,
                  tableView.bounds.width > 0, tableView.bounds.height > 0,
                  let selectedTrackId = configuration.selectedTrackId, consumedSelectedTrackId != selectedTrackId,
                  let indexPath = indexPath(forTrackId: selectedTrackId),
                  indexPath.section < tableView.numberOfSections,
                  indexPath.row < tableView.numberOfRows(inSection: indexPath.section) else { return }
            consumedSelectedTrackId = selectedTrackId
            tableView.selectRow(at: indexPath, animated: false, scrollPosition: .middle)
        }

        func indexPath(forTrackId id: String) -> IndexPath? {
            rows.position(ofTrackID: id).map { IndexPath(row: $0.row, section: $0.section + headerSectionCount) }
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
            return rowSection(forTableSection: section)?.tracks.count ?? 0
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
            configure(cell, with: track, at: indexPath)
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            return nil
        }
        
        public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            guard let title = rowSection(forTableSection: section)?.title, !title.isEmpty else { return nil }

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
            guard let rowSection = rowSection(forTableSection: section) else { return 0 }
            return rowSection.title.isEmpty ? 0 : Self.sectionHeaderHeight
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
            rowSection(forTableSection: indexPath.section) == nil ? UITableView.automaticDimension : configuration.rowHeight
        }

        public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let track = track(at: indexPath) else { return nil }
            let resolvedActions = configuration.interactionModel.resolve(for: track, in: rows.tracks)
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
            let canRemove = configuration.interactionModel.allowsRemovalFromPlaylist(track)
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
            guard configuration.interactionModel.hasContextMenu(for: track) || onRemoveFromPlaylist != nil else { return nil }

            return UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else {
                        completion([])
                        return
                    }

                    let resolvedActions = self.configuration.interactionModel.resolve(for: track, in: self.rows.tracks)
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
            let isFavorited = configuration.interactionModel.isFavorited(track)
            return configured.compactMap { candidate -> UIContextualAction? in
                guard let action = candidate, configuration.interactionModel.hasHandler(for: action) else { return nil }
                let contextual = UIContextualAction(
                    style: .normal,
                    title: TrackActionPresentation.title(for: action, isFavorited: isFavorited)
                ) { [weak self] _, _, completion in
                    guard let self else {
                        completion(false)
                        return
                    }
                    let resolvedActions = self.configuration.interactionModel.resolve(for: track)
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
