import EnsembleCore
import SwiftUI

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
    private let contextMenuButton = UIButton(type: .system)

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
        
        durationLabel.isHidden = true
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
        
        contextMenuButton.setImage(UIImage(systemName: EnsembleDesign.Icon.trackActionsCircle), for: .normal)
        contextMenuButton.tintColor = .secondaryLabel
        contextMenuButton.showsMenuAsPrimaryAction = true
        contextMenuButton.translatesAutoresizingMaskIntoConstraints = false
        contextMenuButton.accessibilityLabel = "Track Actions"
        contentView.addSubview(contextMenuButton)
        
        let widthConstraint = autoplayIndicator.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueGeneratedBadgeDimension)
        self.autoplayWidthConstraint = widthConstraint
        
        NSLayoutConstraint.activate([
            artworkImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.queueHorizontalGutter),
            artworkImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),
            artworkImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),
            
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TrackListLayoutMetrics.defaultTitleTopPadding),
            // Title expands until it hits autoplay indicator (which is pinned right to duration)
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: autoplayIndicator.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: TrackListLayoutMetrics.primarySecondaryTextSpacing),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contextMenuButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            
            playingIndicator.trailingAnchor.constraint(equalTo: contextMenuButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing),
            playingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            playingIndicator.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            playingIndicator.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            
            autoplayIndicator.trailingAnchor.constraint(equalTo: contextMenuButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            autoplayIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            autoplayIndicator.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueGeneratedBadgeDimension),
            widthConstraint,
            
            contextMenuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap),
            contextMenuButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contextMenuButton.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension),
            contextMenuButton.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.queueDragHandleDimension)
        ])
    }
    
    public func configure(
        with item: QueueItem,
        isPlaying: Bool,
        artworkLoader: ArtworkLoaderProtocol,
        contextMenu: UIMenu?
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
        
        durationLabel.text = nil
        durationLabel.isHidden = true
        playingIndicator.isHidden = !isPlaying

        contextMenuButton.menu = contextMenu
        contextMenuButton.isHidden = contextMenu == nil
        
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
                let image = await TrackArtworkThumbnailLoader.image(
                    for: track,
                    artworkLoader: artworkLoader
                ) {
                    self.configureGeneration == expectedGeneration
                }

                if self.configureGeneration == expectedGeneration {
                    self.artworkImageView.image = image
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
        contextMenuButton.menu = nil
    }
}

private final class QueueMoreItemsCell: UITableViewCell {
    private let moreLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        moreLabel.font = .systemFont(ofSize: TrackListLayoutMetrics.nativeSecondaryFontSize, weight: .regular)
        moreLabel.textColor = .secondaryLabel
        moreLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(moreLabel)

        NSLayoutConstraint.activate([
            moreLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TrackListLayoutMetrics.queueHorizontalGutter),
            moreLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -TrackListLayoutMetrics.queueHorizontalGutter),
            moreLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(hiddenCount: Int) {
        moreLabel.text = "\(hiddenCount) more songs"
        accessibilityLabel = moreLabel.text
        selectionStyle = .none
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
    let onAddToLibrary: ((Track) -> Void)?
    let canAddToLibrary: ((Track) -> Bool)?
    let onAddToPlaylist: ((Track) -> Void)?
    let onAddToRecentPlaylist: ((Track) -> Void)?
    let onGoToAlbum: ((Track) -> Void)?
    let onGoToArtist: ((Track) -> Void)?
    let canAddToRecentPlaylist: ((Track) -> Bool)?
    let recentPlaylistTitle: String?
    let onRemoveFromQueue: (Int) -> Void
    let onMoveItem: (String, Int, Int, QueueItemSource?) -> Void

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
        onAddToLibrary: ((Track) -> Void)? = nil,
        canAddToLibrary: ((Track) -> Bool)? = nil,
        onAddToPlaylist: ((Track) -> Void)? = nil,
        onAddToRecentPlaylist: ((Track) -> Void)? = nil,
        onGoToAlbum: ((Track) -> Void)? = nil,
        onGoToArtist: ((Track) -> Void)? = nil,
        canAddToRecentPlaylist: ((Track) -> Bool)? = nil,
        recentPlaylistTitle: String? = nil,
        onRemoveFromQueue: @escaping (Int) -> Void,
        onMoveItem: @escaping (String, Int, Int, QueueItemSource?) -> Void
    ) {
        self.queueItems = queueItems
        self.history = history
        self.showHistory = showHistory
        self.currentQueueIndex = currentQueueIndex
        self.onItemTap = onItemTap
        self.onHistoryTap = onHistoryTap
        self.onPlayNext = onPlayNext
        self.onPlayLast = onPlayLast
        self.onAddToLibrary = onAddToLibrary
        self.canAddToLibrary = canAddToLibrary
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
        // Let UITableView own scrolling and cell recycling for large queues.
        let tableView = UITableView(frame: .zero, style: .grouped)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.dragDelegate = context.coordinator
        tableView.dropDelegate = context.coordinator
        tableView.register(QueueItemCell.self, forCellReuseIdentifier: "QueueItemCell")
        tableView.register(QueueMoreItemsCell.self, forCellReuseIdentifier: "QueueMoreItemsCell")
        tableView.separatorStyle = .singleLine
        tableView.separatorInset = UIEdgeInsets(
            top: 0,
            left: TrackListLayoutMetrics.queueHorizontalGutter,
            bottom: 0,
            right: TrackListLayoutMetrics.queueHorizontalGutter
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
        context.coordinator.onAddToLibrary = onAddToLibrary
        context.coordinator.canAddToLibrary = canAddToLibrary
        context.coordinator.onAddToPlaylist = onAddToPlaylist
        context.coordinator.onAddToRecentPlaylist = onAddToRecentPlaylist
        context.coordinator.onGoToAlbum = onGoToAlbum
        context.coordinator.onGoToArtist = onGoToArtist
        context.coordinator.canAddToRecentPlaylist = canAddToRecentPlaylist
        context.coordinator.recentPlaylistTitle = recentPlaylistTitle
        context.coordinator.onRemoveFromQueue = onRemoveFromQueue
        context.coordinator.onMoveItem = onMoveItem
        context.coordinator.artworkLoader = dependencies.artworkLoader
        if tableView.isEditing == showHistory {
            tableView.setEditing(!showHistory, animated: false)
        }
        
        // Rebuild sections
        context.coordinator.rebuildSections()
        
        if dataChanged {
            tableView.reloadData()
        } else if currentIndexChanged {
            // Only update visible cells
            tableView.visibleCells.forEach { cell in
                if let queueCell = cell as? QueueItemCell,
                   let indexPath = tableView.indexPath(for: cell),
                   !context.coordinator.isMoreRow(indexPath),
                   let item = context.coordinator.item(at: indexPath) {
                    let absoluteIndex = context.coordinator.absoluteQueueIndex(for: indexPath)
                    let isPlaying = absoluteIndex == currentQueueIndex
                    queueCell.configure(
                        with: item,
                        isPlaying: isPlaying,
                        artworkLoader: dependencies.artworkLoader,
                        contextMenu: context.coordinator.contextMenu(for: item.track, absoluteIndex: absoluteIndex)
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
            onAddToLibrary: onAddToLibrary,
            canAddToLibrary: canAddToLibrary,
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
        var onAddToLibrary: ((Track) -> Void)?
        var canAddToLibrary: ((Track) -> Bool)?
        var onAddToPlaylist: ((Track) -> Void)?
        var onAddToRecentPlaylist: ((Track) -> Void)?
        var onGoToAlbum: ((Track) -> Void)?
        var onGoToArtist: ((Track) -> Void)?
        var canAddToRecentPlaylist: ((Track) -> Bool)?
        var recentPlaylistTitle: String?
        var onRemoveFromQueue: (Int) -> Void
        var onMoveItem: (String, Int, Int, QueueItemSource?) -> Void
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService

        var sections: [QueueSection] = []
        weak var tableView: UITableView?
        private let queueDisplayLimit = 50
        private let reorderFeedback = UISelectionFeedbackGenerator()
        private var lastReorderFeedbackIndexPath: IndexPath?

        struct QueueSection {
            let type: SectionType
            let items: [QueueItem]

            enum SectionType {
                case history
                case upNext
                case continuePlaying
                case autoplay
                case more(Int)

                var title: String {
                    switch self {
                    case .history: return "History"
                    case .upNext: return "Up Next"
                    case .continuePlaying: return "Continue Playing"
                    case .autoplay: return "Autoplay"
                    case .more: return ""
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
            onAddToLibrary: ((Track) -> Void)?,
            canAddToLibrary: ((Track) -> Bool)?,
            onAddToPlaylist: ((Track) -> Void)?,
            onAddToRecentPlaylist: ((Track) -> Void)?,
            onGoToAlbum: ((Track) -> Void)?,
            onGoToArtist: ((Track) -> Void)?,
            canAddToRecentPlaylist: ((Track) -> Bool)?,
            recentPlaylistTitle: String?,
            onRemoveFromQueue: @escaping (Int) -> Void,
            onMoveItem: @escaping (String, Int, Int, QueueItemSource?) -> Void,
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
            self.onAddToLibrary = onAddToLibrary
            self.canAddToLibrary = canAddToLibrary
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
                let visibleQueueItems = Array(queueItems.prefix(queueDisplayLimit))
                let hiddenCount = max(0, queueItems.count - queueDisplayLimit)
                let upNext = visibleQueueItems.filter { $0.source == .upNext }
                let continuePlaying = visibleQueueItems.filter { $0.source == .continuePlaying }
                let autoplay = visibleQueueItems.filter { $0.source == .autoplay }

                // Stable sections keep UIKit's cross-section move batch internally consistent.
                sections.append(QueueSection(type: .upNext, items: upNext))
                sections.append(QueueSection(type: .continuePlaying, items: continuePlaying))
                sections.append(QueueSection(type: .autoplay, items: autoplay))
                if hiddenCount > 0 {
                    sections.append(QueueSection(type: .more(hiddenCount), items: []))
                }
            }
        }
        
        func section(at index: Int) -> QueueSection? {
            guard sections.indices.contains(index) else { return nil }
            return sections[index]
        }

        func item(at indexPath: IndexPath) -> QueueItem? {
            guard let section = section(at: indexPath.section),
                  section.items.indices.contains(indexPath.row)
            else { return nil }
            return section.items[indexPath.row]
        }
        
        func absoluteQueueIndex(for indexPath: IndexPath) -> Int? {
            guard !showHistory else { return nil } // History has no queue index
            guard let item = item(at: indexPath) else { return nil }
            return queueItems.firstIndex(where: { $0.id == item.id })
        }
        
        // MARK: - UITableViewDataSource
        
        public func numberOfSections(in tableView: UITableView) -> Int {
            sections.count
        }
        
        public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            guard let section = self.section(at: section) else { return 0 }
            if case .more = section.type {
                return 1
            }
            return section.items.count
        }
        
        public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            guard let section = section(at: indexPath.section) else {
                return UITableViewCell()
            }
            if case let .more(hiddenCount) = section.type {
                let cell = tableView.dequeueReusableCell(withIdentifier: "QueueMoreItemsCell", for: indexPath) as! QueueMoreItemsCell
                cell.configure(hiddenCount: hiddenCount)
                return cell
            }

            let cell = tableView.dequeueReusableCell(withIdentifier: "QueueItemCell", for: indexPath) as! QueueItemCell
            guard let item = item(at: indexPath) else { return cell }
            let absoluteIndex = absoluteQueueIndex(for: indexPath)
            let isPlaying = absoluteIndex == currentQueueIndex
            cell.configure(
                with: item,
                isPlaying: isPlaying,
                artworkLoader: artworkLoader,
                contextMenu: contextMenu(for: item.track, absoluteIndex: absoluteIndex)
            )
            return cell
        }
        
        public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
            return nil // Using custom header view instead
        }
        
        public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
            guard let sectionData = self.section(at: section) else { return nil }
            if sectionData.items.isEmpty {
                return nil
            }
            
            let headerView = UIView()
            headerView.backgroundColor = .clear // Transparent to show blurred background
            
            let label = UILabel()
            label.text = sectionData.type.title
            label.font = .systemFont(ofSize: TrackListLayoutMetrics.nativeSecondaryFontSize, weight: .bold)
            label.textColor = .secondaryLabel
            label.translatesAutoresizingMaskIntoConstraints = false
            
            headerView.addSubview(label)
            
            if case .history = sectionData.type {
                let clockIcon = UIImageView(image: UIImage(systemName: EnsembleDesign.Icon.clock))
                clockIcon.tintColor = .secondaryLabel
                clockIcon.contentMode = .scaleAspectFit
                clockIcon.translatesAutoresizingMaskIntoConstraints = false
                headerView.addSubview(clockIcon)
                
                NSLayoutConstraint.activate([
                    clockIcon.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: TrackListLayoutMetrics.queueHorizontalGutter),
                    clockIcon.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    clockIcon.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.nativeSectionIconDimension),
                    clockIcon.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.nativeSectionIconDimension),
                    
                    label.leadingAnchor.constraint(equalTo: clockIcon.trailingAnchor, constant: TrackListLayoutMetrics.rowTightAccessoryGap),
                    label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding)
                ])
            } else {
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: TrackListLayoutMetrics.queueHorizontalGutter),
                    label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding)
                ])
            }
            
            return headerView
        }
        
        public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            guard let section = self.section(at: section), !section.items.isEmpty else {
                return CGFloat.leastNormalMagnitude
            }
            return 40
        }
        
        public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            TrackListLayoutMetrics.defaultRowHeight
        }
        
        // MARK: - UITableViewDelegate
        
        public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let section = section(at: indexPath.section) else { return }
            if case .more = section.type {
                return
            }
            guard let item = item(at: indexPath) else { return }

            // Handle history items separately
            if case .history = section.type {
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
            guard let section = section(at: indexPath.section) else { return nil }
            if case .more = section.type {
                return nil
            }

            guard let item = item(at: indexPath) else { return nil }
            let absoluteIndex = absoluteQueueIndex(for: indexPath)
            if !isHistorySection(section), absoluteIndex == nil {
                return nil
            }
            
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.contextMenu(for: item.track, absoluteIndex: absoluteIndex)
            }
        }

        func contextMenu(for track: Track, absoluteIndex: Int?) -> UIMenu? {
            let interactionModel = TrackRowInteractionModel(
                onPlayNext: { [weak self] track in self?.onPlayNext(track) },
                onPlayLast: { [weak self] track in self?.onPlayLast(track) },
                onAddToLibrary: self.onAddToLibrary,
                onAddToPlaylist: self.onAddToPlaylist,
                onAddToRecentPlaylist: self.onAddToRecentPlaylist,
                onGoToAlbum: self.onGoToAlbum,
                onGoToArtist: self.onGoToArtist,
                canAddToLibrary: self.canAddToLibrary,
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

        private func isHistorySection(_ section: QueueSection) -> Bool {
            if case .history = section.type {
                return true
            }
            return false
        }
        
        // MARK: - Drag & Drop
        
        public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
            guard !showHistory, let section = section(at: indexPath.section) else { return false }
            if case .more = section.type {
                return false
            }
            return true
        }

        public func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard !showHistory, !isMoreRow(sourceIndexPath) else { return }
            moveQueueRow(from: sourceIndexPath, to: destinationIndexPath)
        }

        public func tableView(
            _ tableView: UITableView,
            targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
            toProposedIndexPath proposedDestinationIndexPath: IndexPath
        ) -> IndexPath {
            if sections.indices.contains(proposedDestinationIndexPath.section),
               case .autoplay = sections[proposedDestinationIndexPath.section].type {
                return sourceIndexPath
            }

            guard sections.indices.contains(proposedDestinationIndexPath.section),
                  case .more = sections[proposedDestinationIndexPath.section].type
            else {
                triggerQueueMoveFeedbackIfNeeded(for: proposedDestinationIndexPath)
                return proposedDestinationIndexPath
            }

            let lastMovableSectionIndex = sections.lastIndex { section in
                if case .more = section.type { return false }
                return !section.items.isEmpty
            }
            guard let sectionIndex = lastMovableSectionIndex else {
                return sourceIndexPath
            }
            let targetIndexPath = IndexPath(row: sections[sectionIndex].items.count - 1, section: sectionIndex)
            triggerQueueMoveFeedbackIfNeeded(for: targetIndexPath)
            return targetIndexPath
        }
        
        public func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            guard !showHistory,
                  !isMoreRow(indexPath),
                  let item = item(at: indexPath)
            else { return [] }
            reorderFeedback.prepare()
            lastReorderFeedbackIndexPath = indexPath
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
            if let destinationIndexPath {
                if sections.indices.contains(destinationIndexPath.section),
                   case .autoplay = sections[destinationIndexPath.section].type {
                    return UITableViewDropProposal(operation: .cancel)
                }
                triggerQueueMoveFeedbackIfNeeded(for: destinationIndexPath)
            }
            return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        public func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {
            lastReorderFeedbackIndexPath = nil
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
            
            commitQueueMove(
                itemId: sourceItem.id,
                sourceIndex: sourceAbsoluteIndex,
                destinationIndex: destinationAbsoluteIndex,
                destinationSource: queueSource(for: destinationIndexPath)
            )
        }

        func isMoreRow(_ indexPath: IndexPath) -> Bool {
            guard sections.indices.contains(indexPath.section) else { return false }
            if case .more = sections[indexPath.section].type {
                return true
            }
            return false
        }

        private func moveQueueRow(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
            guard !isMoreRow(sourceIndexPath),
                  sections.indices.contains(sourceIndexPath.section),
                  sections[sourceIndexPath.section].items.indices.contains(sourceIndexPath.row)
            else { return }

            let sourceItem = sections[sourceIndexPath.section].items[sourceIndexPath.row]
            guard let sourceAbsoluteIndex = queueItems.firstIndex(where: { $0.id == sourceItem.id }) else { return }

            let destinationAbsoluteIndex: Int
            if isMoreRow(destinationIndexPath) {
                destinationAbsoluteIndex = min(queueItems.count, queueDisplayLimit)
            } else if sections.indices.contains(destinationIndexPath.section) {
                let destinationItems = sections[destinationIndexPath.section].items
                if destinationItems.indices.contains(destinationIndexPath.row),
                   let index = queueItems.firstIndex(where: { $0.id == destinationItems[destinationIndexPath.row].id }) {
                    destinationAbsoluteIndex = index
                } else if let lastItem = destinationItems.last,
                          let lastIndex = queueItems.firstIndex(where: { $0.id == lastItem.id }) {
                    destinationAbsoluteIndex = lastIndex + 1
                } else {
                    destinationAbsoluteIndex = queueItems.count
                }
            } else {
                destinationAbsoluteIndex = queueItems.count
            }

            commitQueueMove(
                itemId: sourceItem.id,
                sourceIndex: sourceAbsoluteIndex,
                destinationIndex: destinationAbsoluteIndex,
                destinationSource: queueSource(for: destinationIndexPath)
            )
        }

        private func commitQueueMove(
            itemId: String,
            sourceIndex: Int,
            destinationIndex: Int,
            destinationSource: QueueItemSource?
        ) {
            guard queueItems.indices.contains(sourceIndex),
                  sourceIndex != destinationIndex
                    || destinationSource.map({ $0 != queueItems[sourceIndex].source }) == true,
                  destinationIndex >= 0,
                  destinationIndex <= queueItems.count
            else { return }

            var item = queueItems.remove(at: sourceIndex)
            if let destinationSource {
                item.source = destinationSource
            } else if item.source == .autoplay {
                item.source = .continuePlaying
            }
            let adjustedDestination = destinationIndex > sourceIndex
                ? destinationIndex - 1
                : destinationIndex
            queueItems.insert(item, at: adjustedDestination)
            rebuildSections()

            reorderFeedback.selectionChanged()
            reorderFeedback.prepare()
            onMoveItem(itemId, sourceIndex, destinationIndex, destinationSource)
        }

        private func queueSource(for indexPath: IndexPath) -> QueueItemSource? {
            guard sections.indices.contains(indexPath.section) else { return nil }
            switch sections[indexPath.section].type {
            case .upNext: return .upNext
            case .continuePlaying: return .continuePlaying
            case .history, .autoplay, .more: return nil
            }
        }

        private func triggerQueueMoveFeedbackIfNeeded(for indexPath: IndexPath) {
            guard lastReorderFeedbackIndexPath != indexPath,
                  !isMoreRow(indexPath)
            else { return }
            lastReorderFeedbackIndexPath = indexPath
            reorderFeedback.selectionChanged()
            reorderFeedback.prepare()
        }
    }
}
#endif
