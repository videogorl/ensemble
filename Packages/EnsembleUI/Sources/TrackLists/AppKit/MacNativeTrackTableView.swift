import EnsembleCore
import SwiftUI
import Nuke

#if os(macOS)
import AppKit

struct MacNativeTrackTableView: NSViewRepresentable {
    let sections: [SongsTrackListSection]
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let showAlbumName: Bool
    let tableHeaderContent: AnyView?
    let tableFooterContent: AnyView?
    let currentTrackId: String?
    let availabilityGeneration: UInt64
    let activeDownloadRatingKeys: Set<String>
    let bottomContentInset: CGFloat
    let tableHeaderExtraHeight: CGFloat
    let supplementalMetadataWidth: CGFloat?
    let rowHeight: CGFloat
    let interactionModel: TrackRowInteractionModel
    let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    @Binding var requestedSectionID: String?
    let onTrackTap: (Track, Int) -> Void

    @Environment(\.dependencies) private var dependencies

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = MacNativeContextMenuTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.floatsGroupRows = false
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let column = NSTableColumn(identifier: .track)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = MacNativeTrackScrollView()
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.sections = sections
        context.coordinator.showArtwork = showArtwork
        context.coordinator.showTrackNumbers = showTrackNumbers
        context.coordinator.showAlbumName = showAlbumName
        context.coordinator.tableHeaderContent = tableHeaderContent
        context.coordinator.tableFooterContent = tableFooterContent
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.availabilityGeneration = availabilityGeneration
        context.coordinator.activeDownloadRatingKeys = activeDownloadRatingKeys
        context.coordinator.bottomContentInset = bottomContentInset
        context.coordinator.tableHeaderExtraHeight = tableHeaderExtraHeight
        context.coordinator.supplementalMetadataWidth = supplementalMetadataWidth
        context.coordinator.rowHeight = rowHeight
        context.coordinator.interactionModel = interactionModel
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.shareService = dependencies.shareService
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        context.coordinator.rebuildRows()
        if let trackScrollView = scrollView as? MacNativeTrackScrollView {
            trackScrollView.bottomContentInset = bottomContentInset
        } else {
            let contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomContentInset, right: 0)
            if !scrollView.contentInsets.isApproximatelyEqual(to: contentInsets) {
                scrollView.contentInsets = contentInsets
            }
        }

        if tableView.numberOfRows != context.coordinator.rows.count {
            tableView.reloadData()
        } else {
            context.coordinator.invalidateDynamicRowHeights(in: tableView)
            tableView.enumerateAvailableRowViews { _, row in
                guard row < context.coordinator.rows.count else { return }
                let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                context.coordinator.configure(view: view, row: row)
            }
        }

        if let requestedSectionID,
           let targetRow = context.coordinator.rowIndex(forSectionID: requestedSectionID) {
            tableView.scrollRowToVisible(targetRow)
            DispatchQueue.main.async {
                self.requestedSectionID = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sections: sections,
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            showAlbumName: showAlbumName,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            bottomContentInset: bottomContentInset,
            tableHeaderExtraHeight: tableHeaderExtraHeight,
            supplementalMetadataWidth: supplementalMetadataWidth,
            rowHeight: rowHeight,
            interactionModel: interactionModel,
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var sections: [SongsTrackListSection]
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var showAlbumName: Bool
        var tableHeaderContent: AnyView?
        var tableFooterContent: AnyView?
        var currentTrackId: String?
        var availabilityGeneration: UInt64
        var activeDownloadRatingKeys: Set<String>
        var bottomContentInset: CGFloat
        var tableHeaderExtraHeight: CGFloat
        var supplementalMetadataWidth: CGFloat?
        var rowHeight: CGFloat
        var interactionModel: TrackRowInteractionModel
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        let onTrackTap: (Track, Int) -> Void
        weak var tableView: NSTableView?
        private(set) var rows: [NativeTrackListFlattenedRow] = []

        init(
            sections: [SongsTrackListSection],
            showArtwork: Bool,
            showTrackNumbers: Bool,
            showAlbumName: Bool,
            tableHeaderContent: AnyView?,
            tableFooterContent: AnyView?,
            currentTrackId: String?,
            availabilityGeneration: UInt64,
            activeDownloadRatingKeys: Set<String>,
            bottomContentInset: CGFloat,
            tableHeaderExtraHeight: CGFloat,
            supplementalMetadataWidth: CGFloat?,
            rowHeight: CGFloat,
            interactionModel: TrackRowInteractionModel,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            onRemoveFromPlaylist: ((Track, Int) -> Void)?,
            onTrackTap: @escaping (Track, Int) -> Void
        ) {
            self.sections = sections
            self.showArtwork = showArtwork
            self.showTrackNumbers = showTrackNumbers
            self.showAlbumName = showAlbumName
            self.tableHeaderContent = tableHeaderContent
            self.tableFooterContent = tableFooterContent
            self.currentTrackId = currentTrackId
            self.availabilityGeneration = availabilityGeneration
            self.activeDownloadRatingKeys = activeDownloadRatingKeys
            self.bottomContentInset = bottomContentInset
            self.tableHeaderExtraHeight = tableHeaderExtraHeight
            self.supplementalMetadataWidth = supplementalMetadataWidth
            self.rowHeight = rowHeight
            self.interactionModel = interactionModel
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.onRemoveFromPlaylist = onRemoveFromPlaylist
            self.onTrackTap = onTrackTap
            super.init()
            rebuildRows()
        }

        func rebuildRows() {
            rows = NativeTrackListFlattening.rows(
                sections: sections,
                hasHeader: tableHeaderContent != nil,
                hasFooter: tableFooterContent != nil,
                bottomContentInset: 0
            )
        }

        func rowIndex(forSectionID id: String) -> Int? {
            rows.firstIndex { row in
                if case let .section(sectionID, _) = row {
                    return sectionID == id
                }
                return false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            guard row < rows.count else { return false }
            if case .section = rows[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row < rows.count else { return false }
            if case .track = rows[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return rowHeight }
            if case .section = rows[row] { return 40 }
            if case let .bottomSpacer(height) = rows[row] { return height }
            if case .header = rows[row], let tableHeaderContent {
                return headerHeight(for: tableHeaderContent, width: tableView.bounds.width)
            }
            if case .footer = rows[row], let tableFooterContent {
                return hostingHeight(for: tableFooterContent, width: tableView.bounds.width)
            }
            return rowHeight
        }

        func invalidateDynamicRowHeights(in tableView: NSTableView) {
            let indexes = rows.enumerated().reduce(into: IndexSet()) { result, element in
                switch element.element {
                case .header, .footer, .bottomSpacer:
                    result.insert(element.offset)
                case .section, .track:
                    break
                }
            }

            if !indexes.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: indexes)
            }
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < rows.count else { return nil }

            switch rows[row] {
            case .header:
                guard let tableHeaderContent else { return nil }
                let view = tableView.makeView(withIdentifier: .hostingRow, owner: self) as? MacNativeTrackHostingCell
                    ?? MacNativeTrackHostingCell()
                view.identifier = .hostingRow
                view.configure(rootView: tableHeaderContent)
                return view
            case let .section(_, title):
                let view = tableView.makeView(withIdentifier: .sectionHeader, owner: self) as? MacNativeTrackSectionCell
                    ?? MacNativeTrackSectionCell()
                view.identifier = .sectionHeader
                view.configure(title: title)
                return view
            case .track:
                let view = tableView.makeView(withIdentifier: .trackRow, owner: self) as? MacNativeTrackTableCell
                    ?? MacNativeTrackTableCell()
                view.identifier = .trackRow
                configure(view: view, row: row)
                return view
            case .footer:
                guard let tableFooterContent else { return nil }
                let view = tableView.makeView(withIdentifier: .hostingRow, owner: self) as? MacNativeTrackHostingCell
                    ?? MacNativeTrackHostingCell()
                view.identifier = .hostingRow
                view.configure(rootView: tableFooterContent)
                return view
            case .bottomSpacer:
                let view = tableView.makeView(withIdentifier: .bottomSpacer, owner: self)
                    ?? NSView()
                view.identifier = .bottomSpacer
                return view
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < rows.count,
                  case let .track(track, _) = rows[row] else {
                return nil
            }

            return MediaDragPayload.trackPasteboardWriter(for: track, shareService: shareService)
        }

        func configure(view: NSView?, row: Int) {
            guard row < rows.count,
                  let view = view as? MacNativeTrackTableCell,
                  case let .track(track, globalIndex) = rows[row] else { return }

            let resolvedActions = interactionModel.resolve(for: track)
            view.configure(
                track: track,
                showArtwork: showArtwork,
                showTrackNumber: showTrackNumbers,
                showAlbumName: showAlbumName,
                isPlaying: track.id == currentTrackId,
                isUnavailableOffline: trackAvailabilityResolver.availability(for: track).shouldDim,
                isActivelyDownloading: activeDownloadRatingKeys.contains(track.id),
                isFavorited: resolvedActions.isFavorited,
                supplementalMetadataWidth: supplementalMetadataWidth,
                artworkLoader: artworkLoader,
                menuProvider: { [weak self] in
                    self?.makeMenu(for: track, globalIndex: globalIndex, resolvedActions: resolvedActions)
                }
            )
        }

        @objc func tableClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0,
                  row < rows.count,
                  case let .track(track, globalIndex) = rows[row] else { return }
            onTrackTap(track, globalIndex)
        }

        func tableView(
            _ tableView: NSTableView,
            rowActionsForRow row: Int,
            edge: NSTableView.RowActionEdge
        ) -> [NSTableViewRowAction] {
            guard row < rows.count,
                  case let .track(track, _) = rows[row] else { return [] }
            let layout = DependencyContainer.shared.settingsManager.trackSwipeLayout
            let configured = edge == .leading ? layout.leading : layout.trailing

            return configured.compactMap { candidate in
                guard let action = candidate else { return nil }
                return rowAction(for: action, track: track)
            }
        }

        private func rowAction(for action: TrackSwipeAction, track: Track) -> NSTableViewRowAction? {
            let resolvedActions = interactionModel.resolve(for: track)
            guard NativeTrackSwipeActionPresenter.isSupported(action, resolvedActions: resolvedActions) else { return nil }

            let rowAction = NSTableViewRowAction(
                style: .regular,
                title: NativeTrackSwipeActionPresenter.title(for: action, resolvedActions: resolvedActions)
            ) { [weak self] _, _ in
                if action == .favoriteToggle {
                    self?.showFavoriteLoadingToast(for: track, willFavorite: !resolvedActions.isFavorited)
                }
                NativeTrackSwipeActionPresenter.execute(action, track: track, resolvedActions: resolvedActions)
                self?.showSwipeConfirmation(for: action, track: track)
            }
            rowAction.backgroundColor = NSColor(NativeTrackSwipeActionPresenter.tint(for: action, resolvedActions: resolvedActions))
            rowAction.image = NSImage(
                systemSymbolName: NativeTrackSwipeActionPresenter.systemImage(for: action, resolvedActions: resolvedActions),
                accessibilityDescription: NativeTrackSwipeActionPresenter.title(for: action, resolvedActions: resolvedActions)
            )
            return rowAction
        }

        private func makeMenu(
            for track: Track,
            globalIndex: Int,
            resolvedActions: TrackRowInteractionModel.ResolvedActions
        ) -> NSMenu? {
            NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolvedActions,
                context: onRemoveFromPlaylist == nil ? .library : .playlistTrack(canRemove: true),
                onRemoveFromPlaylist: onRemoveFromPlaylist.map { handler in
                    { handler(track, globalIndex) }
                }
            )
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0,
                  row < rows.count,
                  case let .track(track, globalIndex) = rows[row] else {
                return nil
            }
            return makeMenu(
                for: track,
                globalIndex: globalIndex,
                resolvedActions: interactionModel.resolve(for: track)
            )
        }

        private func hostingHeight(for rootView: AnyView, width: CGFloat) -> CGFloat {
            let hostingView = NSHostingView(rootView: rootView.frame(width: max(width, 1)))
            return max(1, hostingView.fittingSize.height)
        }

        private func headerHeight(for rootView: AnyView, width: CGFloat) -> CGFloat {
            let measuredHeight = hostingHeight(for: rootView, width: width)
            guard width >= EnsembleScaffold.DetailSurface.wideHeaderThreshold else {
                return measuredHeight
            }

            let wideHeaderHeight = ArtworkSize.medium.cgSize.height
                + (EnsembleScaffold.DetailSurface.headerPadding * 2)
                + tableHeaderExtraHeight
            return min(measuredHeight, wideHeaderHeight)
        }

        private func showSwipeConfirmation(for action: TrackSwipeAction, track: Track) {
            guard let toast = NativeTrackSwipeActionPresenter.confirmationToast(
                for: action,
                track: track,
                dedupeNamespace: "mac-songs-table"
            ) else { return }
            Task { @MainActor in
                toastCenter.show(toast)
            }
        }

        private func showFavoriteLoadingToast(for track: Track, willFavorite: Bool) {
            Task { @MainActor in
                toastCenter.show(NativeTrackSwipeActionPresenter.favoriteLoadingToast(
                    for: track,
                    willFavorite: willFavorite,
                    dedupeNamespace: "mac-songs-table"
                )
                )
            }
        }
    }
}

private final class MacNativeContextMenuTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let menu = contextMenuProvider?(row) else {
            return super.menu(for: event)
        }
        return menu
    }
}

private final class MacNativeTrackScrollView: NSScrollView {
    var bottomContentInset: CGFloat = 0 {
        didSet {
            updateContentInsets()
        }
    }

    override func layout() {
        super.layout()
        updateContentInsets()
    }

    private func updateContentInsets() {
        let insets = NSEdgeInsets(
            top: safeAreaInsets.top,
            left: 0,
            bottom: bottomContentInset,
            right: 0
        )
        if !contentInsets.isApproximatelyEqual(to: insets) {
            contentInsets = insets
        }
        scrollerInsets = NSEdgeInsetsZero
    }
}

private final class MacNativeTrackHostingCell: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func configure(rootView: AnyView) {
        if let hostingView {
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            self.hostingView = hostingView
        }
    }
}

private extension NSEdgeInsets {
    func isApproximatelyEqual(to other: NSEdgeInsets) -> Bool {
        abs(top - other.top) < 0.5 &&
        abs(left - other.left) < 0.5 &&
        abs(bottom - other.bottom) < 0.5 &&
        abs(right - other.right) < 0.5
    }
}

private final class MacNativeTrackSectionCell: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(title: String) {
        titleField.stringValue = title
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class MacNativeTrackTableCell: NSTableCellView {
    private let favoriteImageView = NSImageView()
    private let artworkImageView = NSImageView()
    private let trackNumberField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let artistField = NSTextField(labelWithString: "")
    private let albumField = NSTextField(labelWithString: "")
    private let downloadImageView = NSImageView()
    private let durationField = NSTextField(labelWithString: "")
    private let overflowButton = NSButton()
    private let playingImageView = NSImageView()
    private let dividerView = NSView()

    private var titleTopConstraint: NSLayoutConstraint?
    private var titleCenterYConstraint: NSLayoutConstraint?
    private var subtitleTopConstraint: NSLayoutConstraint?
    private var titleLeadingToArtworkConstraint: NSLayoutConstraint?
    private var titleLeadingToTrackNumberConstraint: NSLayoutConstraint?
    private var titleLeadingToContentConstraint: NSLayoutConstraint?
    private var titleTrailingToDurationConstraint: NSLayoutConstraint?
    private var titleTrailingToArtistConstraint: NSLayoutConstraint?
    private var artistTrailingToAlbumConstraint: NSLayoutConstraint?
    private var artistTrailingToDurationConstraint: NSLayoutConstraint?
    private var albumTrailingToDurationConstraint: NSLayoutConstraint?
    private var artistWidthConstraint: NSLayoutConstraint?
    private var albumWidthConstraint: NSLayoutConstraint?
    private var artworkLoadTask: Task<Void, Never>?
    private var currentTrackID: String?
    private var menuProvider: (() -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        currentTrackID = nil
        menuProvider = nil
    }

    func configure(
        track: Track,
        showArtwork: Bool,
        showTrackNumber: Bool,
        showAlbumName: Bool,
        isPlaying: Bool,
        isUnavailableOffline: Bool,
        isActivelyDownloading: Bool,
        isFavorited: Bool,
        supplementalMetadataWidth: CGFloat?,
        artworkLoader: ArtworkLoaderProtocol,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.menuProvider = menuProvider
        titleField.stringValue = track.title
        trackNumberField.stringValue = isPlaying ? "" : "\(track.trackNumber)"
        artistField.stringValue = track.artistName ?? "Unknown Artist"
        albumField.stringValue = track.albumName ?? "Unknown Album"
        durationField.stringValue = track.formattedDuration

        let showsArtist = Self.showsArtistMetadataColumn(for: supplementalMetadataWidth)
        let showsAlbum = showAlbumName && Self.showsAlbumMetadataColumn(for: supplementalMetadataWidth)
        applySupplementalMetadataLayout(width: supplementalMetadataWidth, showsArtist: showsArtist, showsAlbum: showsAlbum)
        applyPrimaryLeadingLayout(showArtwork: showArtwork, showTrackNumber: showTrackNumber)

        var subtitleParts: [String] = []
        if let artist = track.artistName { subtitleParts.append(artist) }
        if showAlbumName, let album = track.albumName { subtitleParts.append(album) }
        subtitleField.stringValue = showsArtist ? "" : subtitleParts.joined(separator: " · ")
        subtitleField.isHidden = showsArtist

        artworkImageView.isHidden = !showArtwork
        trackNumberField.isHidden = !showTrackNumber
        favoriteImageView.isHidden = !isFavorited
        downloadImageView.isHidden = !(track.isDownloaded || isActivelyDownloading)
        playingImageView.isHidden = !isPlaying
        durationField.isHidden = isPlaying
        alphaValue = isUnavailableOffline ? 0.45 : 1

        if !showArtwork {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            currentTrackID = track.id
            artworkImageView.image = nil
        } else if currentTrackID != track.id {
            currentTrackID = track.id
            artworkImageView.image = nil
            loadArtwork(for: track, artworkLoader: artworkLoader)
        }
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        favoriteImageView.image = NSImage(systemSymbolName: EnsembleDesign.Icon.favoriteFilled, accessibilityDescription: "Favorite")
        favoriteImageView.contentTintColor = .systemPink
        favoriteImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favoriteImageView)

        artworkImageView.imageScaling = .scaleAxesIndependently
        artworkImageView.wantsLayer = true
        artworkImageView.layer?.cornerRadius = ArtworkCornerRadius.square(for: .tiny)
        artworkImageView.layer?.masksToBounds = true
        artworkImageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artworkImageView)

        configureTextField(trackNumberField, fontSize: 14, color: .secondaryLabelColor)
        trackNumberField.alignment = .center
        configureTextField(titleField, fontSize: 15, color: .labelColor)
        configureTextField(subtitleField, fontSize: 13, color: .secondaryLabelColor)
        configureTextField(artistField, fontSize: 15, color: .secondaryLabelColor)
        configureTextField(albumField, fontSize: 15, color: .secondaryLabelColor)
        configureTextField(durationField, fontSize: 13, color: .secondaryLabelColor)
        durationField.alignment = .right

        downloadImageView.image = NSImage(systemSymbolName: EnsembleDesign.Icon.downloaded, accessibilityDescription: "Downloaded")
        downloadImageView.contentTintColor = .secondaryLabelColor
        downloadImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(downloadImageView)

        overflowButton.image = NSImage(systemSymbolName: EnsembleDesign.Icon.trackActions, accessibilityDescription: "Track Actions")
        overflowButton.isBordered = false
        overflowButton.target = self
        overflowButton.action = #selector(showMenu(_:))
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overflowButton)

        playingImageView.image = NSImage(systemSymbolName: EnsembleDesign.Icon.speakerPlaying, accessibilityDescription: "Playing")
        playingImageView.contentTintColor = .systemBlue
        playingImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playingImageView)

        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor = TrackListLayoutMetrics.nativeSeparatorColor.cgColor
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        titleTopConstraint = titleField.topAnchor.constraint(equalTo: topAnchor, constant: TrackListLayoutMetrics.defaultTitleTopPadding)
        titleCenterYConstraint = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        subtitleTopConstraint = subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: TrackListLayoutMetrics.primarySecondaryTextSpacing)
        titleLeadingToArtworkConstraint = titleField.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: TrackListLayoutMetrics.rowInterItemSpacing)
        titleLeadingToTrackNumberConstraint = titleField.leadingAnchor.constraint(equalTo: trackNumberField.trailingAnchor, constant: TrackListLayoutMetrics.rowInterItemSpacing)
        titleLeadingToContentConstraint = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding)
        titleTrailingToDurationConstraint = titleField.trailingAnchor.constraint(lessThanOrEqualTo: downloadImageView.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap)
        titleTrailingToArtistConstraint = titleField.trailingAnchor.constraint(lessThanOrEqualTo: artistField.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistTrailingToAlbumConstraint = artistField.trailingAnchor.constraint(equalTo: albumField.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistTrailingToDurationConstraint = artistField.trailingAnchor.constraint(equalTo: downloadImageView.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        albumTrailingToDurationConstraint = albumField.trailingAnchor.constraint(equalTo: downloadImageView.leadingAnchor, constant: -TrackListLayoutMetrics.rowInterItemSpacing)
        artistWidthConstraint = artistField.widthAnchor.constraint(equalToConstant: 0)
        albumWidthConstraint = albumField.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            favoriteImageView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: TrackListLayoutMetrics.favoriteIndicatorCenterX),
            favoriteImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.favoriteIndicatorDimension),
            favoriteImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.favoriteIndicatorDimension),

            artworkImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding),
            artworkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),
            artworkImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.standardArtworkDimension),

            trackNumberField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TrackListLayoutMetrics.rowHorizontalPadding),
            trackNumberField.centerYAnchor.constraint(equalTo: centerYAnchor),
            trackNumberField.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.trackNumberWidth),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleTopConstraint!,

            artistField.centerYAnchor.constraint(equalTo: centerYAnchor),
            albumField.centerYAnchor.constraint(equalTo: centerYAnchor),
            artistWidthConstraint!,
            albumWidthConstraint!,

            overflowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TrackListLayoutMetrics.rowHorizontalPadding),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflowButton.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.overflowControlDimension),
            overflowButton.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.overflowControlDimension),

            durationField.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            durationField.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationField.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.durationColumnWidth),

            downloadImageView.trailingAnchor.constraint(equalTo: durationField.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap),
            downloadImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension),
            downloadImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension),

            playingImageView.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            playingImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension),
            playingImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension),

            dividerView.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
        ])
        titleLeadingToArtworkConstraint?.isActive = true
        titleTopConstraint?.isActive = true
        titleTrailingToDurationConstraint?.isActive = true
    }

    private func configureTextField(_ field: NSTextField, fontSize: CGFloat, color: NSColor) {
        field.font = .systemFont(ofSize: fontSize, weight: .regular)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
    }

    private func applySupplementalMetadataLayout(
        width: CGFloat?,
        showsArtist: Bool,
        showsAlbum: Bool
    ) {
        artistField.isHidden = !showsArtist
        albumField.isHidden = !showsAlbum
        artistWidthConstraint?.constant = showsArtist ? Self.artistMetadataColumnWidth(for: width) : 0
        albumWidthConstraint?.constant = showsAlbum ? Self.albumMetadataColumnWidth(for: width) : 0

        titleTopConstraint?.isActive = !showsArtist
        titleCenterYConstraint?.isActive = showsArtist
        titleTrailingToDurationConstraint?.isActive = !showsArtist
        titleTrailingToArtistConstraint?.isActive = showsArtist
        artistTrailingToAlbumConstraint?.isActive = showsArtist && showsAlbum
        artistTrailingToDurationConstraint?.isActive = showsArtist && !showsAlbum
        albumTrailingToDurationConstraint?.isActive = showsAlbum
    }

    private func applyPrimaryLeadingLayout(showArtwork: Bool, showTrackNumber: Bool) {
        titleLeadingToArtworkConstraint?.isActive = showArtwork
        titleLeadingToTrackNumberConstraint?.isActive = !showArtwork && showTrackNumber
        titleLeadingToContentConstraint?.isActive = !showArtwork && !showTrackNumber
    }

    private func loadArtwork(for track: Track, artworkLoader: ArtworkLoaderProtocol) {
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
                if currentTrackID == track.id {
                    artworkImageView.image = nil
                }
                return
            }

            let request = ImageRequest(url: url)
            if let cachedImage = ImagePipeline.shared.cache.cachedImage(for: request) {
                if currentTrackID == track.id {
                    artworkImageView.image = cachedImage.image
                }
                return
            }

            if let image = try? await ImagePipeline.shared.image(for: request),
               currentTrackID == track.id {
                artworkImageView.image = image
            }
        }
    }

    private static func showsArtistMetadataColumn(for width: CGFloat?) -> Bool {
        TrackListLayoutMetrics.showsArtistMetadataColumn(for: width)
    }

    private static func showsAlbumMetadataColumn(for width: CGFloat?) -> Bool {
        TrackListLayoutMetrics.showsAlbumMetadataColumn(for: width)
    }

    private static func artistMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        TrackListLayoutMetrics.artistMetadataColumnWidth(for: width)
    }

    private static func albumMetadataColumnWidth(for width: CGFloat?) -> CGFloat {
        TrackListLayoutMetrics.albumMetadataColumnWidth(for: width)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let track = NSUserInterfaceItemIdentifier("NativeTrackListHost.TrackColumn")
    static let trackRow = NSUserInterfaceItemIdentifier("NativeTrackListHost.TrackRow")
    static let hostingRow = NSUserInterfaceItemIdentifier("NativeTrackListHost.HostingRow")
    static let sectionHeader = NSUserInterfaceItemIdentifier("NativeTrackListHost.SectionHeader")
    static let bottomSpacer = NSUserInterfaceItemIdentifier("NativeTrackListHost.BottomSpacer")
}
#endif
