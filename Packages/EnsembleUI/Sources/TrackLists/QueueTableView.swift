import EnsembleCore
import SwiftUI
import Nuke

#if canImport(UIKit)
import UIKit

// MARK: - Queue Item Cell

public class QueueItemCell: UITableViewCell {
    private let artworkImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let durationLabel = UILabel()
    private let playingIndicator = UIImageView()
    private let autoplayIndicator = UIImageView()
    private let dragHandleView = UIImageView()

    private var titleLeadingConstraint: NSLayoutConstraint?
    private var subtitleLeadingConstraint: NSLayoutConstraint?
    private var currentItemID: String?
    private var artworkLoadTask: Task<Void, Never>?
    private var autoplayWidthConstraint: NSLayoutConstraint?
    /// Monotonically increasing counter to guard against stale artwork loads.
    /// Each configure() increments this; the async artwork task checks its
    /// captured generation matches before assigning the image.
    private var configureGeneration: UInt = 0
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        // Make cell background transparent to show blur
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkImageView.layer.cornerRadius = ArtworkCornerRadius.square(for: TrackListLayoutMetrics.standardArtworkDimension)
        artworkImageView.backgroundColor = UIColor.systemGray5
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(artworkImageView)
        
        titleLabel.font = .systemFont(ofSize: TrackListLayoutMetrics.nativePrimaryFontSize, weight: .regular)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)
        
        subtitleLabel.font = .systemFont(ofSize: TrackListLayoutMetrics.nativeSecondaryFontSize, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(subtitleLabel)
        
        durationLabel.font = .systemFont(ofSize: TrackListLayoutMetrics.nativeSecondaryFontSize, weight: .regular)
        durationLabel.textColor = .secondaryLabel
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)
        
        playingIndicator.image = UIImage(systemName: EnsembleDesign.Icon.speakerPlaying)
        playingIndicator.tintColor = .systemBlue
        playingIndicator.contentMode = .scaleAspectFit
        playingIndicator.translatesAutoresizingMaskIntoConstraints = false
        playingIndicator.isHidden = true
        contentView.addSubview(playingIndicator)
        
        autoplayIndicator.image = UIImage(systemName: EnsembleDesign.Icon.generatedBadge)
        autoplayIndicator.tintColor = .systemPurple
        autoplayIndicator.contentMode = .scaleAspectFit
        autoplayIndicator.translatesAutoresizingMaskIntoConstraints = false
        autoplayIndicator.isHidden = true
        contentView.addSubview(autoplayIndicator)
        
        dragHandleView.image = UIImage(systemName: EnsembleDesign.Icon.dragReorder)
        dragHandleView.tintColor = .systemGray
        dragHandleView.contentMode = .scaleAspectFit
        dragHandleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dragHandleView)
        
        let widthConstraint = autoplayIndicator.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueGeneratedBadgeDimension)
        self.autoplayWidthConstraint = widthConstraint
        
        NSLayoutConstraint.activate([
            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.detailHorizontalPadding),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),
            artworkImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),
            
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TrackListLayoutMetrics.defaultTitleTopPadding),
            // Title expands until it hits autoplay indicator (which is pinned right to duration)
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: autoplayIndicator.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: TrackListLayoutMetrics.primarySecondaryTextSpacing),
            subtitleLabel.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            
            durationLabel.trailingAnchor.constraint(equalTo: dragHandleView.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing),
            durationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: TrackListLayoutMetrics.durationMinimumWidth),
            
            playingIndicator.trailingAnchor.constraint(equalTo: dragHandleView.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            playingIndicator.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            
            autoplayIndicator.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            autoplayIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            autoplayIndicator.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueGeneratedBadgeDimension),
            widthConstraint,
            
            dragHandleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -TrackListLayoutMetrics.detailHorizontalPadding),
            dragHandleView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dragHandleView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            dragHandleView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension)
        ])
    }
    
    public func configure(
        with item: QueueItem,
        isPlaying: Bool,
        showDragHandle: Bool,
        artworkLoader: ArtworkLoaderProtocol
    ) {
        let track = item.track
        titleLabel.text = track.title
        
        // Autoplay styling
        let isAutoplay = item.source == .autoplay
        titleLabel.textColor = isAutoplay ? .systemPurple : .label
        autoplayIndicator.isHidden = !isAutoplay
        autoplayWidthConstraint?.constant = isAutoplay ? 14 : 0
        
        // Remove old constraints
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false
        
        // Configure leading constraint
        let leadingAnchor = artworkImageView.trailingAnchor
        let constant = TrackListLayoutMetrics.rowInterItemSpacing
        
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        subtitleLeadingConstraint = subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: constant)
        
        titleLeadingConstraint?.isActive = true
        subtitleLeadingConstraint?.isActive = true
        
        var subtitleParts: [String] = []
        if let artist = track.artistName {
            subtitleParts.append(artist)
        }
        subtitleLabel.text = subtitleParts.joined(separator: " · ")
        
        durationLabel.text = track.formattedDuration
        durationLabel.isHidden = isPlaying
        playingIndicator.isHidden = !isPlaying
        
        // Show/hide drag handle
        dragHandleView.isHidden = !showDragHandle
        
        // Load artwork — increment generation so stale loads are discarded
        configureGeneration &+= 1
        let expectedGeneration = configureGeneration

        if currentItemID != item.id {
            currentItemID = item.id
            artworkImageView.image = nil
            artworkImageView.backgroundColor = UIColor.systemGray5

            // Cancel any previous artwork load task
            artworkLoadTask?.cancel()

            artworkLoadTask = Task { @MainActor in
                // Guard: bail if cell was reconfigured since this task started
                guard self.configureGeneration == expectedGeneration else { return }

                guard let url = await artworkLoader.artworkURLAsync(
                    for: track.thumbPath,
                    sourceKey: track.sourceCompositeKey,
                    ratingKey: track.id,
                    fallbackPath: track.fallbackThumbPath,
                    fallbackRatingKey: track.fallbackRatingKey,
                    size: ArtworkSize.thumbnail.rawValue
                ) else {
                    if self.configureGeneration == expectedGeneration {
                        self.artworkImageView.image = nil
                    }
                    return
                }

                guard self.configureGeneration == expectedGeneration else { return }

                let request = ImageRequest(url: url)

                // Check cache first
                if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                    if self.configureGeneration == expectedGeneration {
                        self.artworkImageView.image = cachedImage.image
                    }
                    return
                }

                // Load asynchronously
                if let image = try? await ImagePipeline.shared.image(for: request) {
                    if self.configureGeneration == expectedGeneration {
                        self.artworkImageView.image = image
                    }
                }
            }
        }
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentItemID = nil
        titleLeadingConstraint?.isActive = false
        subtitleLeadingConstraint?.isActive = false
    }
}

// MARK: - Intrinsic Table View

/// A UITableView that adjusts its intrinsicContentSize based on its contentSize.
/// This allows it to be used inside a SwiftUI ScrollView without a fixed height.
internal class IntrinsicTableView: UITableView {
    override var contentSize: CGSize {
        didSet {
            self.invalidateIntrinsicContentSize()
        }
    }
    
    override var intrinsicContentSize: CGSize {
        self.layoutIfNeeded()
        return CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }
}

// MARK: - Queue Table View

public struct QueueTableView: UIViewRepresentable {
    let queueItems: [QueueItem]
    let history: [QueueItem]
    let showHistory: Bool
    let currentQueueIndex: Int
    let onItemTap: (QueueItem, Int) -> Void
    let onHistoryTap: (QueueItem, Int) -> Void  // Called when tapping a history item (item, historyIndex)
    let onPlayNext: (Track) -> Void
    let onPlayLast: (Track) -> Void
    let onAddToPlaylist: ((Track) -> Void)?
    let onAddToRecentPlaylist: ((Track) -> Void)?
    let onGoToAlbum: ((Track) -> Void)?
    let onGoToArtist: ((Track) -> Void)?
    let canAddToRecentPlaylist: ((Track) -> Bool)?
    let recentPlaylistTitle: String?
    let onRemoveFromQueue: (Int) -> Void
    let onMoveItem: (String, Int, Int) -> Void  // itemId, sourceIndex, destinationIndex

    @Environment(\.dependencies) private var dependencies

    public init(
        queueItems: [QueueItem],
        history: [QueueItem],
        showHistory: Bool,
        currentQueueIndex: Int,
        onItemTap: @escaping (QueueItem, Int) -> Void,
        onHistoryTap: @escaping (QueueItem, Int) -> Void,
        onPlayNext: @escaping (Track) -> Void,
        onPlayLast: @escaping (Track) -> Void,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil,
        onRemoveFromQueue: @escaping (Int) -> Void,
        onMoveItem: @escaping (String, Int, Int) -> Void
    ) {
        self.queueItems = queueItems
        self.history = history
        self.showHistory = showHistory
        self.currentQueueIndex = currentQueueIndex
        self.onItemTap = onItemTap
        self.onHistoryTap = onHistoryTap
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToPlaylist = onAddToPlaylist
        self.onAddToRecentPlaylist = onAddToRecentPlaylist
        self.onGoToAlbum = onGoToAlbum
        self.onGoToArtist = onGoToArtist
        self.canAddToRecentPlaylist = canAddToRecentPlaylist
        self.recentPlaylistTitle = recentPlaylistTitle
        self.onRemoveFromQueue = onRemoveFromQueue
        self.onMoveItem = onMoveItem
    }
    
    public func makeUIView(context: Context) -> UITableView {
        // Use regular UITableView (not IntrinsicTableView) so the table manages its
        // own scrolling and cell recycling. IntrinsicTableView forced all cells to
        // render simultaneously via intrinsicContentSize, causing hangs with large queues.
        let tableView = UITableView(frame: .zero, style: .grouped)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.dragDelegate = context.coordinator
        tableView.dropDelegate = context.coordinator
        tableView.register(QueueItemCell.self, forCellReuseIdentifier: "QueueItemCell")
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: TrackListLayoutMetrics.detailHorizontalPadding,
            bottom: 0,
            right: TrackListLayoutMetrics.detailHorizontalPadding
        )
        tableView.separatorColor = TrackListLayoutMetrics.nativeSeparatorColor
        tableView.backgroundColor = .clear
        tableView.isScrollEnabled = true // Table manages its own scrolling
        tableView.dragInteractionEnabled = true
        tableView.setEditing(true, animated: false)
        tableView.allowsSelectionDuringEditing = true
        tableView.contentInsetAdjustmentBehavior = .never
        context.coordinator.tableView = tableView
        return tableView
    }
    
    public func updateUIView(_ tableView: UITableView, context: Context) {
        // Update coordinator state
        let dataChanged = context.coordinator.queueItems.count != queueItems.count ||
            !zip(context.coordinator.queueItems, queueItems).allSatisfy { $0.id == $1.id } ||
            context.coordinator.history.count != history.count ||
            !zip(context.coordinator.history, history).allSatisfy { $0.id == $1.id } ||
            context.coordinator.showHistory != showHistory
        
        let currentIndexChanged = context.coordinator.currentQueueIndex != currentQueueIndex
        
        context.coordinator.queueItems = queueItems
        context.coordinator.history = history
        context.coordinator.showHistory = showHistory
        context.coordinator.currentQueueIndex = currentQueueIndex
        context.coordinator.onItemTap = onItemTap
        context.coordinator.onHistoryTap = onHistoryTap
        context.coordinator.onPlayNext = onPlayNext
        context.coordinator.onPlayLast = onPlayLast
        context.coordinator.onAddToPlaylist = onAddToPlaylist
        context.coordinator.onAddToRecentPlaylist = onAddToRecentPlaylist
        context.coordinator.onGoToAlbum = onGoToAlbum
        context.coordinator.onGoToArtist = onGoToArtist
        context.coordinator.canAddToRecentPlaylist = canAddToRecentPlaylist
        context.coordinator.recentPlaylistTitle = recentPlaylistTitle
        context.coordinator.onRemoveFromQueue = onRemoveFromQueue
        context.coordinator.onMoveItem = onMoveItem
        context.coordinator.artworkLoader = dependencies.artworkLoader
        
        // Rebuild sections
        context.coordinator.rebuildSections()
        
        if dataChanged {
            tableView.reloadData()
        } else if currentIndexChanged {
            // Only update visible cells
            tableView.visibleCells.forEach { cell in
                if let queueCell = cell as? QueueItemCell,
                   let indexPath = tableView.indexPath(for: cell) {
                    let item = context.coordinator.item(at: indexPath)
                    let absoluteIndex = context.coordinator.absoluteQueueIndex(for: indexPath)
                    let isPlaying = absoluteIndex == currentQueueIndex
                    let showDragHandle = !showHistory // No drag handle in history
                    queueCell.configure(
                        with: item,
                        isPlaying: isPlaying,
                        showDragHandle: showDragHandle,
                        artworkLoader: dependencies.artworkLoader
                    )
                }
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            queueItems: queueItems,
            history: history,
            showHistory: showHistory,
            currentQueueIndex: currentQueueIndex,
            onItemTap: onItemTap,
            onHistoryTap: onHistoryTap,
            onPlayNext: onPlayNext,
            onPlayLast: onPlayLast,
            onAddToPlaylist: onAddToPlaylist,
            onAddToRecentPlaylist: onAddToRecentPlaylist,
            onGoToAlbum: onGoToAlbum,
            onGoToArtist: onGoToArtist,
            canAddToRecentPlaylist: canAddToRecentPlaylist,
            recentPlaylistTitle: recentPlaylistTitle,
            onRemoveFromQueue: onRemoveFromQueue,
            onMoveItem: onMoveItem,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService
        )
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate, UITableViewDropDelegate {
        var queueItems: [QueueItem]
        var history: [QueueItem]
        var showHistory: Bool
        var currentQueueIndex: Int
        var onItemTap: (QueueItem, Int) -> Void
        var onHistoryTap: (QueueItem, Int) -> Void
        var onPlayNext: (Track) -> Void
        var onPlayLast: (Track) -> Void
        var onAddToPlaylist: ((Track) -> Void)?
        var onAddToRecentPlaylist: ((Track) -> Void)?
        var onGoToAlbum: ((Track) -> Void)?
        var onGoToArtist: ((Track) -> Void)?
        var canAddToRecentPlaylist: ((Track) -> Bool)?
        var recentPlaylistTitle: String?
        var onRemoveFromQueue: (Int) -> Void
        var onMoveItem: (String, Int, Int) -> Void  // itemId, sourceIndex, destinationIndex
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService

        var sections: [QueueSection] = []
        weak var tableView: UITableView?

        struct QueueSection {
            let type: SectionType
            let items: [QueueItem]

            enum SectionType {
                case history
                case upNext
                case continuePlaying
                case autoplay

                var title: String {
                    switch self {
                    case .history: return "History"
                    case .upNext: return "Up Next"
                    case .continuePlaying: return "Continue Playing"
                    case .autoplay: return "Autoplay"
                    }
                }
            }
        }

        init(
            queueItems: [QueueItem],
            history: [QueueItem],
            showHistory: Bool,
            currentQueueIndex: Int,
            onItemTap: @escaping (QueueItem, Int) -> Void,
            onHistoryTap: @escaping (QueueItem, Int) -> Void,
            onPlayNext: @escaping (Track) -> Void,
            onPlayLast: @escaping (Track) -> Void,
            onAddToPlaylist: ((Track) -> Void)?,
            onAddToRecentPlaylist: ((Track) -> Void)?,
            onGoToAlbum: ((Track) -> Void)?,
            onGoToArtist: ((Track) -> Void)?,
            canAddToRecentPlaylist: ((Track) -> Bool)?,
            recentPlaylistTitle: String?,
            onRemoveFromQueue: @escaping (Int) -> Void,
            onMoveItem: @escaping (String, Int, Int) -> Void,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService
        ) {
            self.queueItems = queueItems
            self.history = history
            self.showHistory = showHistory
            self.currentQueueIndex = currentQueueIndex
            self.onItemTap = onItemTap
            self.onHistoryTap = onHistoryTap
            self.onPlayNext = onPlayNext
            self.onPlayLast = onPlayLast
            self.onAddToPlaylist = onAddToPlaylist
            self.onAddToRecentPlaylist = onAddToRecentPlaylist
            self.onGoToAlbum = onGoToAlbum
            self.onGoToArtist = onGoToArtist
            self.canAddToRecentPlaylist = canAddToRecentPlaylist
            self.recentPlaylistTitle = recentPlaylistTitle
            self.onRemoveFromQueue = onRemoveFromQueue
            self.onMoveItem = onMoveItem
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            super.init()
            rebuildSections()
        }
        
        func rebuildSections() {
            sections = []
            
            if showHistory {
                if !history.isEmpty {
                    sections.append(QueueSection(
                        type: .history,
                        items: Array(history.reversed())
                    ))
                }
            } else {
                // Split queue by source
                let upNext = queueItems.filter { $0.source == .upNext }
                let continuePlaying = queueItems.filter { $0.source == .continuePlaying }
                let autoplay = queueItems.filter { $0.source == .autoplay }
                
                if !upNext.isEmpty {
                    sections.append(QueueSection(type: .upNext, items: upNext))
                }
                if !continuePlaying.isEmpty {
                    sections.append(QueueSection(type: .continuePlaying, items: continuePlaying))
                }
                if !autoplay.isEmpty {
                    sections.append(QueueSection(type: .autoplay, items: autoplay))
                }
            }
        }
        
        func item(at indexPath: IndexPath) -> QueueItem {
            sections[indexPath.section].items[indexPath.row]
        }
        
        func absoluteQueueIndex(for indexPath: IndexPath) -> Int? {
            guard !showHistory else { return nil } // History has no queue index
            let item = self.item(at: indexPath)
            return queueItems.firstIndex(where: { $0.id == item.id })
        }
        
        // MARK: - UITableViewDataSource
        
        public func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }
        
        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            sections[section].items.count
        }
        
        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "QueueItemCell", for: indexPath) as! QueueItemCell
            let item = self.item(at: indexPath)
            let absoluteIndex = absoluteQueueIndex(for: indexPath)
            let isPlaying = absoluteIndex == currentQueueIndex
            let showDragHandle = !showHistory // No drag handle in history
            cell.configure(
                with: item,
                isPlaying: isPlaying,
                showDragHandle: showDragHandle,
                artworkLoader: artworkLoader
            )
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            return nil // Using custom header view instead
        }
        
        public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            let sectionData = sections[section]
            
            let headerView = UIView()
            headerView.backgroundColor = .clear // Transparent to show blurred background
            
            let label = UILabel()
            label.text = sectionData.type.title
            label.font = .systemFont(ofSize: TrackListLayoutMetrics.nativeSecondaryFontSize, weight: .bold)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            
            headerView.addSubview(label)
            
            if sectionData.type == .history {
                let clockIcon = UIImageView(image: UIImage(systemName: EnsembleDesign.Icon.clock))
                clockIcon.tintColor = .secondaryLabel
                clockIcon.contentMode = .scaleAspectFit
                clockIcon.translatesAutoresizingMaskIntoConstraints = false
                headerView.addSubview(clockIcon)
                
                NSLayoutConstraint.activate([
                    clockIcon.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: TrackListLayoutMetrics.detailHorizontalPadding),
                    clockIcon.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    clockIcon.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.nativeSectionIconDimension),
                    clockIcon.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.nativeSectionIconDimension),
                    
                    label.leadingAnchor.constraint(equalTo: clockIcon.trailingAnchor, constant: TrackListLayoutMetrics.rowTightAccessoryGap),
                    label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding)
                ])
            } else {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: TrackListLayoutMetrics.detailHorizontalPadding),
                    label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding)
                ])
            }
            
            return headerView
        }
        
        public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            40
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            TrackListLayoutMetrics.defaultRowHeight
        }
        
        // MARK: - UITableViewDelegate
        
        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            let item = self.item(at: indexPath)
            let section = sections[indexPath.section]

            // Handle history items separately
            if section.type == .history {
                // History is displayed reversed (most recent first), so convert index
                // back to original history array index
                let originalHistoryIndex = history.count - 1 - indexPath.row
                onHistoryTap(item, originalHistoryIndex)
            } else if let absoluteIndex = absoluteQueueIndex(for: indexPath) {
                onItemTap(item, absoluteIndex)
            }
        }
        
        public func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
            .none // We use drag handles, not delete buttons
        }
        
        public func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
            false
        }
        
        // MARK: - Context Menu
        
        public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            let item = self.item(at: indexPath)
            let section = sections[indexPath.section]
            let absoluteIndex = absoluteQueueIndex(for: indexPath)
            if section.type != .history, absoluteIndex == nil {
                return nil
            }
            
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.contextMenu(for: item.track, absoluteIndex: absoluteIndex)
            }
        }

        private func contextMenu(for track: Track, absoluteIndex: Int?) -> UIMenu? {
            let interactionModel = TrackRowInteractionModel(
                onPlayNext: { [weak self] track in self?.onPlayNext(track) },
                onPlayLast: { [weak self] track in self?.onPlayLast(track) },
                onAddToPlaylist: self.onAddToPlaylist,
                onAddToRecentPlaylist: self.onAddToRecentPlaylist,
                onGoToAlbum: self.onGoToAlbum,
                onGoToArtist: self.onGoToArtist,
                canAddToRecentPlaylist: self.canAddToRecentPlaylist,
                recentPlaylistTitle: self.recentPlaylistTitle
            )
            let resolvedActions = interactionModel.resolve(for: track)

            return NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolvedActions,
                context: absoluteIndex == nil ? .history : .queue(canRemove: true),
                onRemoveFromQueue: absoluteIndex.map { index in
                    { [weak self] in
                        self?.onRemoveFromQueue(index)
                    }
                }
            )
        }
        
        // MARK: - Drag & Drop
        
        public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
            !showHistory // History not movable
        }
        
        public func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard !showHistory else { return [] }
            let item = self.item(at: indexPath)
            let itemProvider = MediaDragPayload.trackItemProvider(for: item.track, shareService: shareService)
            itemProvider.registerObject(item.id as NSString, visibility: .ownProcess)
            let dragItem = UIDragItem(itemProvider: itemProvider)
            dragItem.localObject = item
            return [dragItem]
        }
        
        public func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
            session.canLoadObjects(ofClass: NSString.self)
        }
        
        public func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
            guard destinationIndexPath != nil, !showHistory else {
                return UITableViewDropProposal(operation: .cancel)
            }
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }
        
        public func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
            guard let destinationIndexPath = coordinator.destinationIndexPath,
                  !showHistory else { return }
            
            // Extract source item from the drag item's localObject
            guard let dragItem = coordinator.items.first?.dragItem,
                  let sourceItem = dragItem.localObject as? QueueItem else { return }
            
            // Calculate absolute indices
            // Source absolute index: position of the item in the full queue
            let sourceAbsoluteIndex: Int
            if let index = queueItems.firstIndex(where: { $0.id == sourceItem.id }) {
                sourceAbsoluteIndex = index
            } else {
                return  // Source item not found
            }
            
            // Destination absolute index: position in the full queue
            let sections = self.sections
            let sectionIndex = destinationIndexPath.section
            let rowIndex = destinationIndexPath.row
            
            let destinationAbsoluteIndex: Int
            
            if sectionIndex < sections.count {
                let sectionItems = sections[sectionIndex].items
                if rowIndex < sectionItems.count {
                    // Dropping onto/before an existing item
                    let destinationItem = sectionItems[rowIndex]
                    if let index = queueItems.firstIndex(where: { $0.id == destinationItem.id }) {
                        destinationAbsoluteIndex = index
                    } else {
                        destinationAbsoluteIndex = queueItems.count
                    }
                } else {
                    // Dropping at the end of the section
                    // Find largest index of any item in this section?
                    // Actually, if we drop after the last item of this section, we want to be *after* it in the flat list.
                    if let lastItem = sectionItems.last,
                       let lastIndex = queueItems.firstIndex(where: { $0.id == lastItem.id }) {
                        destinationAbsoluteIndex = lastIndex + 1
                    } else {
                        // Section is empty or items not found - default to end
                        destinationAbsoluteIndex = queueItems.count
                    }
                }
            } else {
                destinationAbsoluteIndex = queueItems.count
            }
            
            EnsembleLogger.debug("Drag-drop: source '\(sourceItem.track.title)' from \(sourceAbsoluteIndex) to \(destinationAbsoluteIndex)")
            
            // Pass item ID + both absolute indices
            onMoveItem(sourceItem.id, sourceAbsoluteIndex, destinationAbsoluteIndex)
        }
    }
}
#endif
