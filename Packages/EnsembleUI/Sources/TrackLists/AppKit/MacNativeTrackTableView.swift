import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

#if os(macOS)
import AppKit

struct MacNativeTrackTableView: NSViewRepresentable {
    let sections: [NativeTrackListSection]
    let showArtwork: Bool
    let showTrackNumbers: Bool
    let showAlbumName: Bool
    let tableHeaderContent: AnyView?
    let tableFooterContent: AnyView?
    let currentTrackId: String?
    let selectedTrackId: String?
    let contentRevision: UInt64?
    let availabilityGeneration: UInt64
    let activeDownloadTrackIdentities: Set<String>
    let bottomContentInset: CGFloat
    let tableHeaderExtraHeight: CGFloat
    let usesDynamicTableHeaderHeight: Bool
    let supplementalMetadataWidth: CGFloat?
    let trackSourceLabels: [String: String]
    let rowHeight: CGFloat
    let interactionModel: TrackRowInteractionModel
    let onRemoveFromPlaylist: ((Track, Int) -> Void)?
    let sectionScrollRequest: TrackSectionScrollRequest?
    let onTrackTap: (Track, Int) -> Void

    @Environment(\.dependencies) private var dependencies

    static func deterministicWideHeaderHeight(tableHeaderExtraHeight: CGFloat) -> CGFloat {
        ArtworkSize.medium.cgSize.height
            + EnsembleScaffold.DetailSurface.macWideHeaderTopPadding
            + EnsembleScaffold.DetailSurface.macWideHeaderBottomPadding
            + tableHeaderExtraHeight
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
        let contentChanged = if let contentRevision {
            coordinator.contentRevision != contentRevision
        } else {
            coordinator.sections != sections
        }
        let structureChanged = contentChanged ||
            (coordinator.tableHeaderContent == nil) != (tableHeaderContent == nil) ||
            (coordinator.tableFooterContent == nil) != (tableFooterContent == nil) ||
            coordinator.bottomContentInset != bottomContentInset
        coordinator.sections = sections
        coordinator.contentRevision = contentRevision
        context.coordinator.showArtwork = showArtwork
        context.coordinator.showTrackNumbers = showTrackNumbers
        context.coordinator.showAlbumName = showAlbumName
        context.coordinator.tableHeaderContent = tableHeaderContent
        context.coordinator.tableFooterContent = tableFooterContent
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.availabilityGeneration = availabilityGeneration
        context.coordinator.activeDownloadTrackIdentities = activeDownloadTrackIdentities
        context.coordinator.bottomContentInset = bottomContentInset
        context.coordinator.tableHeaderExtraHeight = tableHeaderExtraHeight
        context.coordinator.usesDynamicTableHeaderHeight = usesDynamicTableHeaderHeight
        context.coordinator.supplementalMetadataWidth = supplementalMetadataWidth
        context.coordinator.trackSourceLabels = trackSourceLabels
        context.coordinator.rowHeight = rowHeight
        context.coordinator.interactionModel = interactionModel
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.shareService = dependencies.shareService
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.onRemoveFromPlaylist = onRemoveFromPlaylist
        if structureChanged {
            coordinator.rebuildRows()
        }

        if structureChanged || tableView.numberOfRows != coordinator.rows.count {
            tableView.reloadData()
        } else {
            coordinator.invalidateDynamicRowHeights(in: tableView)
            tableView.enumerateAvailableRowViews { _, row in
                guard row < coordinator.rows.count else { return }
                let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                coordinator.configure(view: view, row: row)
                coordinator.configureHostingView(view, row: row, in: tableView)
            }
        }

        if let sectionScrollRequest,
           context.coordinator.consumedSectionScrollRequestID != sectionScrollRequest.id,
           let targetRow = context.coordinator.rowIndex(forSectionID: sectionScrollRequest.sectionID) {
            tableView.scrollRowToVisible(targetRow)
            context.coordinator.consumedSectionScrollRequestID = sectionScrollRequest.id
        }

        if let selectedTrackId,
           context.coordinator.consumedSelectedTrackId != selectedTrackId,
           let targetRow = context.coordinator.rowIndex(forTrackId: selectedTrackId) {
            tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(targetRow)
            context.coordinator.consumedSelectedTrackId = selectedTrackId
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sections: sections,
            contentRevision: contentRevision,
            showArtwork: showArtwork,
            showTrackNumbers: showTrackNumbers,
            showAlbumName: showAlbumName,
            tableHeaderContent: tableHeaderContent,
            tableFooterContent: tableFooterContent,
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadTrackIdentities: activeDownloadTrackIdentities,
            bottomContentInset: bottomContentInset,
            tableHeaderExtraHeight: tableHeaderExtraHeight,
            usesDynamicTableHeaderHeight: usesDynamicTableHeaderHeight,
            supplementalMetadataWidth: supplementalMetadataWidth,
            trackSourceLabels: trackSourceLabels,
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
        var sections: [NativeTrackListSection]
        var contentRevision: UInt64?
        var showArtwork: Bool
        var showTrackNumbers: Bool
        var showAlbumName: Bool
        var tableHeaderContent: AnyView?
        var tableFooterContent: AnyView?
        var currentTrackId: String?
        var availabilityGeneration: UInt64
        var activeDownloadTrackIdentities: Set<String>
        var bottomContentInset: CGFloat
        var tableHeaderExtraHeight: CGFloat
        var usesDynamicTableHeaderHeight: Bool
        var supplementalMetadataWidth: CGFloat?
        var trackSourceLabels: [String: String]
        var rowHeight: CGFloat
        var interactionModel: TrackRowInteractionModel
        var artworkLoader: ArtworkLoaderProtocol
        var shareService: ShareService
        var toastCenter: ToastCenter
        var trackAvailabilityResolver: TrackAvailabilityResolver
        var onRemoveFromPlaylist: ((Track, Int) -> Void)?
        let onTrackTap: (Track, Int) -> Void
        weak var tableView: NSTableView?
        var consumedSectionScrollRequestID: Int?
        var consumedSelectedTrackId: String?
        private(set) var rows: [NativeTrackListFlattenedRow] = []
        // Sharing a sizing host replaces the header tree each time the footer is measured.
        private var headerMeasuringView: NSHostingView<AnyView>?
        private var footerMeasuringView: NSHostingView<AnyView>?
        private var measuredHeader: (width: CGFloat, height: CGFloat)?
        private var measuredFooter: (width: CGFloat, height: CGFloat)?

        init(
            sections: [NativeTrackListSection],
            contentRevision: UInt64? = nil,
            showArtwork: Bool,
            showTrackNumbers: Bool,
            showAlbumName: Bool,
            tableHeaderContent: AnyView?,
            tableFooterContent: AnyView?,
            currentTrackId: String?,
            availabilityGeneration: UInt64,
            activeDownloadTrackIdentities: Set<String>,
            bottomContentInset: CGFloat,
            tableHeaderExtraHeight: CGFloat,
            usesDynamicTableHeaderHeight: Bool,
            supplementalMetadataWidth: CGFloat?,
            trackSourceLabels: [String: String],
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
            self.contentRevision = contentRevision
            self.showArtwork = showArtwork
            self.showTrackNumbers = showTrackNumbers
            self.showAlbumName = showAlbumName
            self.tableHeaderContent = tableHeaderContent
            self.tableFooterContent = tableFooterContent
            self.currentTrackId = currentTrackId
            self.availabilityGeneration = availabilityGeneration
            self.activeDownloadTrackIdentities = activeDownloadTrackIdentities
            self.bottomContentInset = bottomContentInset
            self.tableHeaderExtraHeight = tableHeaderExtraHeight
            self.usesDynamicTableHeaderHeight = usesDynamicTableHeaderHeight
            self.supplementalMetadataWidth = supplementalMetadataWidth
            self.trackSourceLabels = trackSourceLabels
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
                bottomContentInset: bottomContentInset
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
            rows.firstIndex { row in
                if case let .track(track, _) = row {
                    return track.playbackIdentity == id
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

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = tableView.makeView(withIdentifier: .nonClippingRow, owner: self) as? MacNativeTrackRowView
                ?? MacNativeTrackRowView()
            view.identifier = .nonClippingRow
            return view
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return rowHeight }
            if case .section = rows[row] { return 40 }
            if case let .bottomSpacer(height) = rows[row] { return height }
            if case .header = rows[row], let tableHeaderContent {
                return headerHeight(for: tableHeaderContent, in: tableView)
            }
            if case .footer = rows[row], let tableFooterContent {
                return footerHeight(for: tableFooterContent, width: tableView.bounds.width)
            }
            return rowHeight
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
                let row = rows.count - (bottomContentInset > 0 ? 2 : 1)
                if row >= 0 {
                    let height = footerHeight(for: tableFooterContent, width: tableView.bounds.width, forceMeasure: true)
                    if abs(tableView.rect(ofRow: row).height - height) > 0.5 {
                        indexes.insert(row)
                    }
                }
            }
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
            guard row < rows.count,
                  case let .track(track, _) = rows[row] else {
                return nil
            }

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
                guard row < rows.count,
                      case let .track(track, _) = rows[row] else {
                    return nil
                }
                return MediaDragPayload.track(track).items.first
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
            guard row < rows.count,
                  let view = view as? MacNativeTrackTableCell,
                  case let .track(track, globalIndex) = rows[row] else { return }

            view.configure(
                track: track,
                showArtwork: showArtwork,
                showTrackNumber: showTrackNumbers,
                showAlbumName: showAlbumName,
                isPlaying: track.playbackIdentity == currentTrackId,
                isUnavailableOffline: trackAvailabilityResolver.availability(for: track).shouldDim,
                isActivelyDownloading: activeDownloadTrackIdentities.contains(track.sourceScopedID),
                isFavorited: interactionModel.isFavorited(track),
                supplementalMetadataWidth: supplementalMetadataWidth,
                sourceLabel: track.sourceCompositeKey.flatMap { trackSourceLabels[$0] },
                artworkLoader: artworkLoader,
                menuProvider: { [weak self] in
                    guard let self else { return nil }
                    return self.makeMenu(
                        for: track,
                        globalIndex: globalIndex,
                        resolvedActions: self.interactionModel.resolve(for: track, in: self.sections.flatMap(\.tracks))
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
            let slots = MacNativeTrackTableView.appKitRowActionSlots(for: configured, edge: edge)
            guard slots.contains(where: { $0 != nil }) else { return [] }
            let resolvedActions = interactionModel.resolve(for: track)

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
                let currentActions = self.interactionModel.resolve(for: track)
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
            let canRemove = interactionModel.allowsRemovalFromPlaylist(track)
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
            guard row >= 0,
                  row < rows.count,
                  case let .track(track, globalIndex) = rows[row] else {
                return nil
            }
            return makeMenu(
                for: track,
                globalIndex: globalIndex,
                resolvedActions: interactionModel.resolve(for: track, in: sections.flatMap(\.tracks))
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
            if !usesDynamicTableHeaderHeight, width >= EnsembleScaffold.DetailSurface.wideHeaderThreshold {
                return MacNativeTrackTableView.deterministicWideHeaderHeight(
                    tableHeaderExtraHeight: tableHeaderExtraHeight
                )
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
        sourceLabel: String?,
        artworkLoader: ArtworkLoaderProtocol,
        menuProvider: @escaping () -> NSMenu?
    ) {
        self.menuProvider = menuProvider
        setText(track.title, on: titleField)
        setText(isPlaying ? "" : "\(track.trackNumber)", on: trackNumberField)
        setText([track.artistName ?? "Unknown Artist", sourceLabel]
            .compactMap { $0 }
            .joined(separator: " · "), on: artistField)
        setText(track.albumName ?? "Unknown Album", on: albumField)
        setText(track.formattedDuration, on: durationField)

        let showsArtist = Self.showsArtistMetadataColumn(for: supplementalMetadataWidth)
        let showsAlbum = showAlbumName && Self.showsAlbumMetadataColumn(for: supplementalMetadataWidth)
        applySupplementalMetadataLayout(width: supplementalMetadataWidth, showsArtist: showsArtist, showsAlbum: showsAlbum)
        applyPrimaryLeadingLayout(showArtwork: showArtwork, showTrackNumber: showTrackNumber)

        var subtitleParts: [String] = []
        if let artist = track.artistName { subtitleParts.append(artist) }
        if showAlbumName, let album = track.albumName { subtitleParts.append(album) }
        if let unavailableReason = track.unavailableReason { subtitleParts.append(unavailableReason) }
        if let sourceLabel { subtitleParts.append(sourceLabel) }
        setText(showsArtist ? "" : subtitleParts.joined(separator: " · "), on: subtitleField)
        subtitleField.isHidden = showsArtist

        artworkImageView.isHidden = !showArtwork
        trackNumberField.isHidden = !showTrackNumber
        favoriteImageView.isHidden = !isFavorited
        downloadImageView.isHidden = !(track.isDownloaded || isActivelyDownloading)
        playingImageView.isHidden = !isPlaying
        durationField.isHidden = isPlaying
        alphaValue = isUnavailableOffline ? 0.45 : 1

        let playbackIdentity = track.playbackIdentity
        if !showArtwork {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            currentTrackID = playbackIdentity
            artworkImageView.image = nil
        } else if currentTrackID != playbackIdentity {
            currentTrackID = playbackIdentity
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

    private func applySupplementalMetadataLayout(
        width: CGFloat?,
        showsArtist: Bool,
        showsAlbum: Bool
    ) {
        artistField.isHidden = !showsArtist
        albumField.isHidden = !showsAlbum
        artistWidthConstraint?.constant = showsArtist ? Self.artistMetadataColumnWidth(for: width) : 0
        albumWidthConstraint?.constant = showsAlbum ? Self.albumMetadataColumnWidth(for: width) : 0

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

    private func loadArtwork(for track: Track, artworkLoader: ArtworkLoaderProtocol) {
        artworkLoadTask?.cancel()
        artworkLoadTask = Task { @MainActor in
            let image = await TrackArtworkThumbnailLoader.image(
                for: track,
                artworkLoader: artworkLoader
            ) {
                currentTrackID == track.playbackIdentity
            }

            if currentTrackID == track.playbackIdentity {
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
    static let track = NSUserInterfaceItemIdentifier("SongsTrackListHost.TrackColumn")
    static let trackRow = NSUserInterfaceItemIdentifier("SongsTrackListHost.TrackRow")
    static let hostingRow = NSUserInterfaceItemIdentifier("SongsTrackListHost.HostingRow")
    static let sectionHeader = NSUserInterfaceItemIdentifier("SongsTrackListHost.SectionHeader")
    static let bottomSpacer = NSUserInterfaceItemIdentifier("SongsTrackListHost.BottomSpacer")
    static let nonClippingRow = NSUserInterfaceItemIdentifier("SongsTrackListHost.NonClippingRow")
}
#endif
