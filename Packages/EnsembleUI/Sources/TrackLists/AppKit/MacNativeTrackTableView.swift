import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

#if os(macOS)
import AppKit

/// AppKit table behind `TrackListHost` on macOS.
struct MacNativeTrackTableView: NSViewRepresentable {
    let sections: [NativeTrackListSection]
    let configuration: NativeTrackListConfiguration
    let tableHeaderContent: AnyView?
    let tableFooterContent: AnyView?
    let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    let sectionScrollRequest: TrackSectionScrollRequest?
    let onTrackTap: (Track, Int) -> Void

    @Environment(DependencyContainer.self) private var dependencies
    @Environment(\.trackListDisplayRatingsRevision) private var displayRatingsRevision

    static var deterministicWideHeaderHeight: CGFloat {
        ArtworkSize.medium.cgSize.height
            + EnsembleScaffold.DetailSurface.macWideHeaderTopPadding
            + EnsembleScaffold.DetailSurface.macWideHeaderBottomPadding
    }

    static func appKitRowActionSlots(
        for configured: [TrackSwipeAction?],
        edge: NSTableView.RowActionEdge
    ) -> [TrackSwipeAction?] {
        switch edge {
        case .leading:
            return configured
        case .trailing:
            // AppKit paints trailing row actions opposite UIKit's visual slot order.
            return Array(configured.reversed())
        @unknown default:
            return configured
        }
    }

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
        tableView.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let column = NSTableColumn(identifier: .track)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        let newState = makeState()
        let change = TrackListChange.between(coordinator.state, newState)
        if change != .none {
            EnsembleLogger.debug("Track table \(change) (\(newState.rows.sections.count) sections)")
        }
        coordinator.state = newState
        coordinator.configuration = configuration
        // Hosted cells are separate SwiftUI roots and do not inherit the environment.
        coordinator.tableHeaderContent = tableHeaderContent.map { AnyView($0.environment(dependencies)) }
        coordinator.tableFooterContent = tableFooterContent.map { AnyView($0.environment(dependencies)) }
        coordinator.artworkLoader = dependencies.artworkLoader
        coordinator.shareService = dependencies.shareService
        coordinator.toastCenter = dependencies.toastCenter
        coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        coordinator.settingsManager = dependencies.settingsManager
        coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        if change == .reload {
            coordinator.rebuildRows()
        }

        if change == .reload || tableView.numberOfRows != coordinator.rows.count {
            tableView.reloadData()
        } else {
            // Header and footer content can change without a structural change.
            coordinator.invalidateDynamicRowHeights(in: tableView)
            tableView.enumerateAvailableRowViews { _, row in
                guard row < coordinator.rows.count else { return }
                let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                if change == .reconfigureVisibleRows {
                    coordinator.configure(view: view, row: row)
                }
                coordinator.configureHostingView(view, row: row, in: tableView)
            }
        }

        if let sectionScrollRequest,
           context.coordinator.consumedSectionScrollRequestID != sectionScrollRequest.id,
           let targetRow = context.coordinator.rowIndex(forSectionID: sectionScrollRequest.sectionID) {
            tableView.scrollRowToVisible(targetRow)
            context.coordinator.consumedSectionScrollRequestID = sectionScrollRequest.id
        }

        if let selectedTrackId = configuration.selectedTrackId,
           context.coordinator.consumedSelectedTrackId != selectedTrackId,
           let targetRow = context.coordinator.rowIndex(forTrackId: selectedTrackId) {
            tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(targetRow)
            context.coordinator.consumedSelectedTrackId = selectedTrackId
        }
    }

    private func makeState() -> TrackListChange.State {
        TrackListChange.State(
            rows: TrackListRows(sections: sections),
            contentRevision: configuration.contentRevision,
            hasHeader: tableHeaderContent != nil,
            hasFooter: tableFooterContent != nil,
            bottomSpacer: configuration.bottomContentInset,
            rowState: TrackListChange.RowState(
                configuration: configuration,
                isOffline: !dependencies.networkMonitor.isConnected,
                displayRatingsRevision: displayRatingsRevision
            )
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: makeState(),
            configuration: configuration,
            tableHeaderContent: tableHeaderContent.map { AnyView($0.environment(dependencies)) },
            tableFooterContent: tableFooterContent.map { AnyView($0.environment(dependencies)) },
            artworkLoader: dependencies.artworkLoader,
            shareService: dependencies.shareService,
            toastCenter: dependencies.toastCenter,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            settingsManager: dependencies.settingsManager,
            onRemoveFromPlaylist: onRemoveFromPlaylist,
            onTrackTap: onTrackTap
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var state: TrackListChange.State
        var configuration: NativeTrackListConfiguration
        var tableHeaderContent: AnyView?
        var tableFooterContent: AnyView?
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var settingsManager: SettingsManager
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        let onTrackTap: (Track, Int) -> Void
        weak var tableView: NSTableView?
        var consumedSectionScrollRequestID: Int?
        var consumedSelectedTrackId: String?
        private(set) var rows: [TrackListRows.FlatRow] = []
        // Sharing a sizing host replaces the header tree each time the footer is measured.
        private var headerMeasuringView: NSHostingView<AnyView>?
        private var footerMeasuringView: NSHostingView<AnyView>?
        private var measuredHeader: (width: CGFloat, height: CGFloat)?
        private var measuredFooter: (width: CGFloat, height: CGFloat)?

        init(
            state: TrackListChange.State,
            configuration: NativeTrackListConfiguration,
            tableHeaderContent: AnyView?,
            tableFooterContent: AnyView?,
            artworkLoader: ArtworkLoaderProtocol,
            shareService: ShareService,
            toastCenter: ToastCenter,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            settingsManager: SettingsManager,
            onRemoveFromPlaylist: ((Track, Int) -> Void)?,
            onTrackTap: @escaping (Track, Int) -> Void
        ) {
            self.state = state
            self.configuration = configuration
            self.tableHeaderContent = tableHeaderContent
            self.tableFooterContent = tableFooterContent
            self.artworkLoader = artworkLoader
            self.shareService = shareService
            self.toastCenter = toastCenter
            self.settingsManager = settingsManager
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.onRemoveFromPlaylist = onRemoveFromPlaylist
            self.onTrackTap = onTrackTap
            super.init()
            rebuildRows()
        }

        func rebuildRows() {
            rows = state.rows.flattened(
                hasHeader: state.hasHeader,
                hasFooter: state.hasFooter,
                bottomContentInset: state.bottomSpacer
            )
            measuredHeader = nil
            measuredFooter = nil
        }

        func rowIndex(forSectionID id: String) -> Int? {
            rows.firstIndex { row in
                if case let .section(sectionID, _) = row {
                    return sectionID == id
                }
                return false
            }
        }

        func rowIndex(forTrackId id: String) -> Int? {
            guard let position = state.rows.position(ofTrackID: id) else { return nil }
            return rows.firstIndex { $0 == .track(section: position.section, row: position.row) }
        }

        /// The track shown in a flat row and its global index.
        private func indexedTrack(atRow row: Int) -> (track: Track, index: Int)? {
            guard rows.indices.contains(row),
                  case let .track(section, sectionRow) = rows[row] else { return nil }
            return state.rows.track(section: section, row: sectionRow)
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

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: .nonClippingRow, owner: self) as? MacNativeTrackRowView
                ?? MacNativeTrackRowView()
            view.identifier = .nonClippingRow
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return configuration.rowHeight }
            if case .section = rows[row] { return TrackListLayoutMetrics.nativeMacSectionHeaderRowHeight }
            if case let .bottomSpacer(height) = rows[row] { return height }
            if case .header = rows[row], let tableHeaderContent {
                return headerHeight(for: tableHeaderContent, in: tableView)
            }
            if case .footer = rows[row], let tableFooterContent {
                return footerHeight(for: tableFooterContent, width: tableView.bounds.width)
            }
            return configuration.rowHeight
        }

        func invalidateDynamicRowHeights(in tableView: NSTableView) {
            var indexes = IndexSet()
            if let tableHeaderContent, !rows.isEmpty {
                let height = headerHeight(for: tableHeaderContent, in: tableView, forceMeasure: true)
                if abs(tableView.rect(ofRow: 0).height - height) > 0.5 {
                    indexes.insert(0)
                }
            }
            if let tableFooterContent {
                let row = rows.count - (configuration.bottomContentInset > 0 ? 2 : 1)
                if row >= 0 {
                    let height = footerHeight(for: tableFooterContent, width: tableView.bounds.width, forceMeasure: true)
                    if abs(tableView.rect(ofRow: row).height - height) > 0.5 {
                        indexes.insert(row)
                    }
                }
            }
            let bottomContentInset = configuration.bottomContentInset
            if bottomContentInset > 0, let row = rows.indices.last,
               abs(tableView.rect(ofRow: row).height - bottomContentInset) > 0.5 {
                indexes.insert(row)
            }

            if !indexes.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    tableView.noteHeightOfRows(withIndexesChanged: indexes)
                }
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
                view.configure(rootView: headerRootView(tableHeaderContent, width: effectiveTableWidth(tableView)))
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
            guard case let (track, _)? = indexedTrack(atRow: row) else { return nil }
            return MediaDragPayload.trackPasteboardWriter(for: track, shareService: shareService)
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            let items = rowIndexes.compactMap { row -> MediaDragPayload.Item? in
                indexedTrack(atRow: row).flatMap { MediaDragPayload.track($0.track).items.first }
            }
            guard !items.isEmpty else { return }
            MacSidebarPlaylistDropRegistry.shared.beginDragging(MediaDragPayload(items: items))
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            movedTo screenPoint: NSPoint
        ) {
            MacSidebarPlaylistDropRegistry.shared.updateTarget(at: screenPoint)
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            // SwiftUI's outline view consumes the native drop without invoking its
            // row handler, so this registered sidebar target owns the local result.
            _ = MacSidebarPlaylistDropRegistry.shared.performDrop(at: screenPoint)
            MacSidebarPlaylistDropRegistry.shared.endDragging()
        }

        func configure(view: NSView?, row: Int) {
            guard let view = view as? MacNativeTrackTableCell,
                  case let (track, globalIndex)? = indexedTrack(atRow: row) else { return }

            view.configure(
                track: track,
                content: TrackRowContent(
                    track: track,
                    configuration: configuration,
                    isDimmed: trackAvailabilityResolver.availability(for: track).shouldDim
                ),
                artworkLoader: artworkLoader,
                menuProvider: { [weak self] in
                    guard let self else { return nil }
                    return self.makeMenu(
                        for: track,
                        globalIndex: globalIndex,
                        resolvedActions: self.configuration.interactionModel.resolve(for: track, in: self.state.rows.tracks)
                    )
                }
            )
        }

        func configureHostingView(_ view: NSView?, row: Int, in tableView: NSTableView) {
            guard row < rows.count,
                  let view = view as? MacNativeTrackHostingCell else { return }

            switch rows[row] {
            case .header:
                guard let tableHeaderContent else { return }
                view.configure(rootView: headerRootView(tableHeaderContent, width: effectiveTableWidth(tableView)))
            case .footer:
                guard let tableFooterContent else { return }
                view.configure(rootView: tableFooterContent)
            case .section, .track, .bottomSpacer:
                return
            }
        }

        @objc func tableDoubleClicked(_ sender: NSTableView) {
            guard case let (track, globalIndex)? = indexedTrack(atRow: sender.clickedRow) else { return }
            onTrackTap(track, globalIndex)
        }

        func tableView(
            _ tableView: NSTableView,
            rowActionsForRow row: Int,
            edge: NSTableView.RowActionEdge
        ) -> [NSTableViewRowAction] {
            guard case let (track, _)? = indexedTrack(atRow: row) else { return [] }
            let layout = settingsManager.trackSwipeLayout
            let configured = edge == .leading ? layout.leading : layout.trailing
            let slots = MacNativeTrackTableView.appKitRowActionSlots(for: configured, edge: edge)
            guard slots.contains(where: { $0 != nil }) else { return [] }
            let resolvedActions = configuration.interactionModel.resolve(for: track)

            return slots.compactMap { candidate in
                guard let action = candidate else { return nil }
                return rowAction(for: action, track: track, resolvedActions: resolvedActions)
            }
        }

        private func rowAction(
            for action: TrackSwipeAction,
            track: Track,
            resolvedActions: TrackRowInteractionModel.ResolvedActions
        ) -> NSTableViewRowAction? {
            guard TrackActionPresentation.isSupported(action, resolvedActions: resolvedActions) else { return nil }

            let rowAction = NSTableViewRowAction(
                style: .regular,
                title: TrackActionPresentation.title(for: action, resolvedActions: resolvedActions)
            ) { [weak self] _, _ in
                guard let self else { return }
                let currentActions = self.configuration.interactionModel.resolve(for: track)
                guard TrackActionPresentation.isSupported(action, resolvedActions: currentActions) else { return }
                if action == .favoriteToggle {
                    self.showFavoriteLoadingToast(for: track, willFavorite: !currentActions.isFavorited)
                }
                TrackActionPresentation.execute(action, resolvedActions: currentActions)
                self.showSwipeConfirmation(for: action, track: track)
            }
            rowAction.backgroundColor = NSColor(TrackActionPresentation.tint(for: action, resolvedActions: resolvedActions))
            rowAction.image = NSImage(
                systemSymbolName: TrackActionPresentation.systemImage(for: action, resolvedActions: resolvedActions),
                accessibilityDescription: TrackActionPresentation.title(for: action, resolvedActions: resolvedActions)
            )
            return rowAction
        }

        private func makeMenu(
            for track: Track,
            globalIndex: Int,
            resolvedActions: TrackRowInteractionModel.ResolvedActions
        ) -> NSMenu? {
            let canRemove = configuration.interactionModel.allowsRemovalFromPlaylist(track)
            return NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolvedActions,
                context: onRemoveFromPlaylist == nil ? .library : .playlistTrack(canRemove: canRemove),
                onRemoveFromPlaylist: canRemove ? onRemoveFromPlaylist.map { handler in
                    { handler(track, globalIndex) }
                } : nil
            )
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard case let (track, globalIndex)? = indexedTrack(atRow: row) else { return nil }
            return makeMenu(
                for: track,
                globalIndex: globalIndex,
                resolvedActions: configuration.interactionModel.resolve(for: track, in: state.rows.tracks)
            )
        }

        private static func hostingHeight(
            for rootView: AnyView,
            width: CGFloat,
            measuringView: inout NSHostingView<AnyView>?
        ) -> CGFloat {
            let content = AnyView(rootView.frame(width: max(width, 1)))
            if let measuringView {
                measuringView.rootView = content
            } else {
                measuringView = NSHostingView(rootView: content)
            }
            return max(1, measuringView?.fittingSize.height ?? 1)
        }

        private func headerHeight(for rootView: AnyView, in tableView: NSTableView, forceMeasure: Bool = false) -> CGFloat {
            let width = effectiveTableWidth(tableView)
            if !configuration.usesDynamicTableHeaderHeight, width >= EnsembleScaffold.DetailSurface.wideHeaderThreshold {
                return MacNativeTrackTableView.deterministicWideHeaderHeight
            }

            if !forceMeasure, let measuredHeader, measuredHeader.width == width {
                return measuredHeader.height
            }
            let height = Self.hostingHeight(
                for: headerRootView(rootView, width: width), width: width,
                measuringView: &headerMeasuringView
            )
            measuredHeader = (width, height)
            return height
        }

        private func footerHeight(for rootView: AnyView, width: CGFloat, forceMeasure: Bool = false) -> CGFloat {
            if !forceMeasure, let measuredFooter, measuredFooter.width == width {
                return measuredFooter.height
            }
            let height = Self.hostingHeight(for: rootView, width: width, measuringView: &footerMeasuringView)
            measuredFooter = (width, height)
            return height
        }

        private func effectiveTableWidth(_ tableView: NSTableView) -> CGFloat {
            let measuredWidth = max(
                tableView.bounds.width,
                tableView.enclosingScrollView?.contentView.bounds.width ?? 0,
                tableView.enclosingScrollView?.bounds.width ?? 0
            )
            return measuredWidth > 1 ? measuredWidth : EnsembleScaffold.DetailSurface.wideHeaderThreshold
        }

        private func headerRootView(_ rootView: AnyView, width: CGFloat) -> AnyView {
            AnyView(rootView.nativeTrackListHeaderWidth(max(width, 1)))
        }

        private func showSwipeConfirmation(for action: TrackSwipeAction, track: Track) {
            guard let toast = TrackActionPresentation.confirmationToast(
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
                toastCenter.show(TrackActionPresentation.favoriteLoadingToast(
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

private final class MacNativeTrackRowView: NSTableRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = false
    }
}

private final class MacNativeTrackHostingCell: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func configure(rootView: AnyView) {
        clipsToBounds = false
        layer?.masksToBounds = false
        if let hostingView {
            hostingView.clipsToBounds = false
            hostingView.layer?.masksToBounds = false
            hostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.clipsToBounds = false
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.layer?.masksToBounds = false
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
        layer?.backgroundColor = NSColor.clear.cgColor
        titleField.font = .systemFont(
            ofSize: TrackListLayoutMetrics.nativeMacSectionHeaderFontSize,
            weight: .semibold
        )
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
    private let artwork = TrackCellArtwork()
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
        artwork.reset()
        menuProvider = nil
    }

    func configure(
        track: Track,
        content: TrackRowContent,
        artworkLoader: ArtworkLoaderProtocol,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.menuProvider = menuProvider
        setText(content.title, on: titleField)
        setText(content.trackNumber, on: trackNumberField)
        setText(content.artistColumn, on: artistField)
        setText(content.albumColumn, on: albumField)
        setText(content.duration, on: durationField)

        let showsArtist = content.artistColumnWidth != nil
        applySupplementalMetadataLayout(artistWidth: content.artistColumnWidth, albumWidth: content.albumColumnWidth)
        applyPrimaryLeadingLayout(showArtwork: content.showsArtwork, showTrackNumber: content.showsTrackNumber)

        setText(showsArtist ? "" : content.subtitle, on: subtitleField)
        subtitleField.isHidden = showsArtist

        artworkImageView.isHidden = !content.showsArtwork
        trackNumberField.isHidden = !content.showsTrackNumber
        favoriteImageView.isHidden = !content.isFavorited
        downloadImageView.isHidden = content.downloadState == .none
        playingImageView.isHidden = !content.isPlaying
        durationField.isHidden = content.isPlaying
        alphaValue = content.isDimmed ? TrackListLayoutMetrics.unavailableRowAlpha : 1

        if content.showsArtwork {
            artwork.show(track, artworkLoader: artworkLoader) { [weak artworkImageView] image in
                artworkImageView?.image = image
            }
        } else {
            artwork.reset()
            artworkImageView.image = nil
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

        configureTextField(
            trackNumberField,
            fontSize: TrackListLayoutMetrics.nativeMacSecondaryFontSize,
            color: .secondaryLabelColor
        )
        trackNumberField.alignment = .center
        configureTextField(
            titleField,
            fontSize: TrackListLayoutMetrics.nativeMacPrimaryFontSize,
            color: .labelColor
        )
        configureTextField(
            subtitleField,
            fontSize: TrackListLayoutMetrics.nativeMacSecondaryFontSize,
            color: .secondaryLabelColor
        )
        configureTextField(
            artistField,
            fontSize: TrackListLayoutMetrics.nativeMacPrimaryFontSize,
            color: .secondaryLabelColor
        )
        configureTextField(
            albumField,
            fontSize: TrackListLayoutMetrics.nativeMacPrimaryFontSize,
            color: .secondaryLabelColor
        )
        configureTextField(
            durationField,
            fontSize: TrackListLayoutMetrics.nativeMacSecondaryFontSize,
            color: .secondaryLabelColor
        )
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

    private func setText(_ text: String, on field: NSTextField) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func setActive(_ constraint: NSLayoutConstraint?, _ isActive: Bool) {
        if let constraint, constraint.isActive != isActive { constraint.isActive = isActive }
    }

    private func applySupplementalMetadataLayout(artistWidth: CGFloat?, albumWidth: CGFloat?) {
        let showsArtist = artistWidth != nil
        let showsAlbum = albumWidth != nil
        artistField.isHidden = !showsArtist
        albumField.isHidden = !showsAlbum
        artistWidthConstraint?.constant = artistWidth ?? 0
        albumWidthConstraint?.constant = albumWidth ?? 0

        setActive(titleTopConstraint, !showsArtist)
        setActive(titleCenterYConstraint, showsArtist)
        setActive(titleTrailingToDurationConstraint, !showsArtist)
        setActive(titleTrailingToArtistConstraint, showsArtist)
        setActive(artistTrailingToAlbumConstraint, showsArtist && showsAlbum)
        setActive(artistTrailingToDurationConstraint, showsArtist && !showsAlbum)
        setActive(albumTrailingToDurationConstraint, showsAlbum)
    }

    private func applyPrimaryLeadingLayout(showArtwork: Bool, showTrackNumber: Bool) {
        setActive(titleLeadingToArtworkConstraint, showArtwork)
        setActive(titleLeadingToTrackNumberConstraint, !showArtwork && showTrackNumber)
        setActive(titleLeadingToContentConstraint, !showArtwork && !showTrackNumber)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let track = NSUserInterfaceItemIdentifier("TrackListHost.TrackColumn")
    static let trackRow = NSUserInterfaceItemIdentifier("TrackListHost.TrackRow")
    static let hostingRow = NSUserInterfaceItemIdentifier("TrackListHost.HostingRow")
    static let sectionHeader = NSUserInterfaceItemIdentifier("TrackListHost.SectionHeader")
    static let bottomSpacer = NSUserInterfaceItemIdentifier("TrackListHost.BottomSpacer")
    static let nonClippingRow = NSUserInterfaceItemIdentifier("TrackListHost.NonClippingRow")
}
#endif
