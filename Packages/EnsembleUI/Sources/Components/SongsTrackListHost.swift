import EnsembleCore
import SwiftUI
import Nuke

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Section model used by `SongsTrackListHost` so Songs can share one native table
/// host across indexed and flat layouts.
public struct SongsTrackListSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let tracks: [Track]

    public init(id: String, title: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.tracks = tracks
    }
}

/// Platform host for dense Songs track lists.
///
/// iOS/iPadOS uses `MediaTrackList` (`UITableView`) and macOS uses an AppKit
/// `NSTableView`. The calling view owns filtering/sorting; this host owns the
/// native row backend and section index wiring.
public struct SongsTrackListHost: View {
    private let sections: [SongsTrackListSection]
    private let currentTrackId: String?
    private let availabilityGeneration: UInt64
    private let activeDownloadRatingKeys: Set<String>
    private let bottomContentInset: CGFloat
    private let supplementalMetadataWidth: CGFloat?
    private let showsSectionIndex: Bool
    private let interactionModel: TrackRowInteractionModel
    private let onTrackTap: (Track, Int) -> Void

    @State private var requestedSectionID: String?

    private var allTracks: [Track] {
        sections.flatMap(\.tracks)
    }

    public init(
        tracks: [Track],
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        interactionModel: TrackRowInteractionModel,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = [
            SongsTrackListSection(id: "all", title: "", tracks: tracks)
        ]
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadRatingKeys = activeDownloadRatingKeys
        self.bottomContentInset = bottomContentInset
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.showsSectionIndex = false
        self.interactionModel = interactionModel
        self.onTrackTap = onTrackTap
    }

    public init(
        sections: [SongsTrackListSection],
        currentTrackId: String? = nil,
        availabilityGeneration: UInt64 = 0,
        activeDownloadRatingKeys: Set<String> = [],
        bottomContentInset: CGFloat = 0,
        supplementalMetadataWidth: CGFloat? = nil,
        showsSectionIndex: Bool = true,
        interactionModel: TrackRowInteractionModel,
        onTrackTap: @escaping (Track, Int) -> Void
    ) {
        self.sections = sections
        self.currentTrackId = currentTrackId
        self.availabilityGeneration = availabilityGeneration
        self.activeDownloadRatingKeys = activeDownloadRatingKeys
        self.bottomContentInset = bottomContentInset
        self.supplementalMetadataWidth = supplementalMetadataWidth
        self.showsSectionIndex = showsSectionIndex
        self.interactionModel = interactionModel
        self.onTrackTap = onTrackTap
    }

    public var body: some View {
        #if os(iOS)
        iOSTrackList
        #elseif os(macOS)
        macTrackList
        #else
        EmptyView()
        #endif
    }

    #if os(iOS)
    private var iOSTrackList: some View {
        Group {
            if showsSectionIndex {
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sections) { section in
                                    iOSSection(section, allTracks: allTracks)
                                }
                            }
                            .padding(.vertical)
                        }

                        sectionIndex { sectionID in
                            proxy.scrollTo(sectionID, anchor: .top)
                        }
                    }
                }
            } else {
                MediaTrackList(
                    tracks: allTracks,
                    showArtwork: true,
                    showTrackNumbers: false,
                    groupByDisc: false,
                    currentTrackId: currentTrackId,
                    availabilityGeneration: availabilityGeneration,
                    activeDownloadRatingKeys: activeDownloadRatingKeys,
                    managesOwnScrolling: true,
                    bottomContentInset: bottomContentInset,
                    interactionModel: interactionModel,
                    supplementalMetadataWidth: supplementalMetadataWidth
                ) { track, index in
                    onTrackTap(track, index)
                }
            }
        }
    }

    private func iOSSection(
        _ section: SongsTrackListSection,
        allTracks: [Track]
    ) -> some View {
        let height = CGFloat(section.tracks.count) * TrackListLayoutMetrics.defaultRowHeight

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader(section.title)

            MediaTrackList(
                tracks: section.tracks,
                showArtwork: true,
                showTrackNumbers: false,
                groupByDisc: false,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                interactionModel: interactionModel,
                supplementalMetadataWidth: supplementalMetadataWidth
            ) { track, _ in
                onTrackTap(track, allTracks.firstIndex(where: { $0.id == track.id }) ?? 0)
            }
            .frame(height: height)
        }
        .id(section.id)
    }
    #endif

    #if os(macOS)
    private var macTrackList: some View {
        ZStack(alignment: .trailing) {
            MacSongsTrackTableView(
                sections: sections,
                currentTrackId: currentTrackId,
                availabilityGeneration: availabilityGeneration,
                activeDownloadRatingKeys: activeDownloadRatingKeys,
                bottomContentInset: bottomContentInset,
                supplementalMetadataWidth: supplementalMetadataWidth,
                interactionModel: interactionModel,
                requestedSectionID: $requestedSectionID,
                onTrackTap: onTrackTap
            )

            sectionIndex { sectionID in
                requestedSectionID = sectionID
            }
        }
    }
    #endif

    @ViewBuilder
    private func sectionIndex(onTap: @escaping (String) -> Void) -> some View {
        if showsSectionIndex && !sections.isEmpty {
            ScrollIndex(
                letters: sections.map(\.title),
                currentLetter: .constant(nil),
                onLetterTap: onTap
            )
            .libraryScrollIndexPositioning(.centered)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        EnsembleBrowseSectionHeader(title, backgroundColor: platformBackground)
    }

    private var platformBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #elseif os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color.clear
        #endif
    }
}

#if os(macOS)
private struct MacSongsTrackTableView: NSViewRepresentable {
    let sections: [SongsTrackListSection]
    let currentTrackId: String?
    let availabilityGeneration: UInt64
    let activeDownloadRatingKeys: Set<String>
    let bottomContentInset: CGFloat
    let supplementalMetadataWidth: CGFloat?
    let interactionModel: TrackRowInteractionModel
    @Binding var requestedSectionID: String?
    let onTrackTap: (Track, Int) -> Void

    @Environment(\.dependencies) private var dependencies

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableClicked(_:))

        let column = NSTableColumn(identifier: .track)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
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
        context.coordinator.currentTrackId = currentTrackId
        context.coordinator.availabilityGeneration = availabilityGeneration
        context.coordinator.activeDownloadRatingKeys = activeDownloadRatingKeys
        context.coordinator.bottomContentInset = bottomContentInset
        context.coordinator.supplementalMetadataWidth = supplementalMetadataWidth
        context.coordinator.interactionModel = interactionModel
        context.coordinator.artworkLoader = dependencies.artworkLoader
        context.coordinator.toastCenter = dependencies.toastCenter
        context.coordinator.trackAvailabilityResolver = dependencies.trackAvailabilityResolver
        context.coordinator.rebuildRows()

        if tableView.numberOfRows != context.coordinator.rows.count {
            tableView.reloadData()
        } else {
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
            currentTrackId: currentTrackId,
            availabilityGeneration: availabilityGeneration,
            activeDownloadRatingKeys: activeDownloadRatingKeys,
            bottomContentInset: bottomContentInset,
            supplementalMetadataWidth: supplementalMetadataWidth,
            interactionModel: interactionModel,
            artworkLoader: dependencies.artworkLoader,
            toastCenter: dependencies.toastCenter,
            trackAvailabilityResolver: dependencies.trackAvailabilityResolver,
            onTrackTap: onTrackTap
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Row {
            case section(SongsTrackListSection)
            case track(Track, globalIndex: Int)
            case bottomSpacer(CGFloat)
        }

        var sections: [SongsTrackListSection]
        var currentTrackId: String?
        var availabilityGeneration: UInt64
        var activeDownloadRatingKeys: Set<String>
        var bottomContentInset: CGFloat
        var supplementalMetadataWidth: CGFloat?
        var interactionModel: TrackRowInteractionModel
        var artworkLoader: ArtworkLoaderProtocol
        var toastCenter: ToastCenter
        var trackAvailabilityResolver: TrackAvailabilityResolver
        let onTrackTap: (Track, Int) -> Void
        weak var tableView: NSTableView?
        private(set) var rows: [Row] = []

        init(
            sections: [SongsTrackListSection],
            currentTrackId: String?,
            availabilityGeneration: UInt64,
            activeDownloadRatingKeys: Set<String>,
            bottomContentInset: CGFloat,
            supplementalMetadataWidth: CGFloat?,
            interactionModel: TrackRowInteractionModel,
            artworkLoader: ArtworkLoaderProtocol,
            toastCenter: ToastCenter,
            trackAvailabilityResolver: TrackAvailabilityResolver,
            onTrackTap: @escaping (Track, Int) -> Void
        ) {
            self.sections = sections
            self.currentTrackId = currentTrackId
            self.availabilityGeneration = availabilityGeneration
            self.activeDownloadRatingKeys = activeDownloadRatingKeys
            self.bottomContentInset = bottomContentInset
            self.supplementalMetadataWidth = supplementalMetadataWidth
            self.interactionModel = interactionModel
            self.artworkLoader = artworkLoader
            self.toastCenter = toastCenter
            self.trackAvailabilityResolver = trackAvailabilityResolver
            self.onTrackTap = onTrackTap
            super.init()
            rebuildRows()
        }

        func rebuildRows() {
            var nextRows: [Row] = []
            var globalIndex = 0
            for section in sections {
                if !section.title.isEmpty {
                    nextRows.append(.section(section))
                }
                for track in section.tracks {
                    nextRows.append(.track(track, globalIndex: globalIndex))
                    globalIndex += 1
                }
            }
            if bottomContentInset > 0 {
                nextRows.append(.bottomSpacer(bottomContentInset))
            }
            rows = nextRows
        }

        func rowIndex(forSectionID id: String) -> Int? {
            rows.firstIndex { row in
                if case let .section(section) = row {
                    return section.id == id
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

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return TrackListLayoutMetrics.defaultRowHeight }
            if case .section = rows[row] { return 40 }
            if case let .bottomSpacer(height) = rows[row] { return height }
            return TrackListLayoutMetrics.defaultRowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < rows.count else { return nil }

            switch rows[row] {
            case let .section(section):
                let view = tableView.makeView(withIdentifier: .sectionHeader, owner: self) as? MacSongsSectionCell
                    ?? MacSongsSectionCell()
                view.identifier = .sectionHeader
                view.configure(title: section.title)
                return view
            case .track:
                let view = tableView.makeView(withIdentifier: .trackRow, owner: self) as? MacSongsTrackCell
                    ?? MacSongsTrackCell()
                view.identifier = .trackRow
                configure(view: view, row: row)
                return view
            case .bottomSpacer:
                let view = tableView.makeView(withIdentifier: .bottomSpacer, owner: self)
                    ?? NSView()
                view.identifier = .bottomSpacer
                return view
            }
        }

        func configure(view: NSView?, row: Int) {
            guard row < rows.count,
                  let view = view as? MacSongsTrackCell,
                  case let .track(track, _) = rows[row] else { return }

            let resolvedActions = interactionModel.resolve(for: track)
            view.configure(
                track: track,
                isPlaying: track.id == currentTrackId,
                isUnavailableOffline: trackAvailabilityResolver.availability(for: track).shouldDim,
                isActivelyDownloading: activeDownloadRatingKeys.contains(track.id),
                isFavorited: resolvedActions.isFavorited,
                supplementalMetadataWidth: supplementalMetadataWidth,
                artworkLoader: artworkLoader,
                menuProvider: { [weak self] in
                    self?.makeMenu(for: track, resolvedActions: resolvedActions)
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
            resolvedActions: TrackRowInteractionModel.ResolvedActions
        ) -> NSMenu? {
            NativeMediaTableActionBuilder.contextMenu(for: track, resolvedActions: resolvedActions)
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

private final class MacSongsSectionCell: NSTableCellView {
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

private final class MacSongsTrackCell: NSTableCellView {
    private let favoriteImageView = NSImageView()
    private let artworkImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let artistField = NSTextField(labelWithString: "")
    private let albumField = NSTextField(labelWithString: "")
    private let downloadImageView = NSImageView()
    private let durationField = NSTextField(labelWithString: "")
    private let overflowButton = NSButton()
    private let playingImageView = NSImageView()

    private var titleTopConstraint: NSLayoutConstraint?
    private var titleCenterYConstraint: NSLayoutConstraint?
    private var subtitleTopConstraint: NSLayoutConstraint?
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
        artistField.stringValue = track.artistName ?? "Unknown Artist"
        albumField.stringValue = track.albumName ?? "Unknown Album"
        durationField.stringValue = track.formattedDuration

        let showsArtist = Self.showsArtistMetadataColumn(for: supplementalMetadataWidth)
        let showsAlbum = Self.showsAlbumMetadataColumn(for: supplementalMetadataWidth)
        applySupplementalMetadataLayout(width: supplementalMetadataWidth, showsArtist: showsArtist, showsAlbum: showsAlbum)

        var subtitleParts: [String] = []
        if let artist = track.artistName { subtitleParts.append(artist) }
        if let album = track.albumName { subtitleParts.append(album) }
        subtitleField.stringValue = showsArtist ? "" : subtitleParts.joined(separator: " · ")
        subtitleField.isHidden = showsArtist

        favoriteImageView.isHidden = !isFavorited
        downloadImageView.isHidden = !(track.isDownloaded || isActivelyDownloading)
        playingImageView.isHidden = !isPlaying
        durationField.isHidden = isPlaying
        alphaValue = isUnavailableOffline ? 0.45 : 1

        if currentTrackID != track.id {
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

        titleTopConstraint = titleField.topAnchor.constraint(equalTo: topAnchor, constant: TrackListLayoutMetrics.defaultTitleTopPadding)
        titleCenterYConstraint = titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        subtitleTopConstraint = subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: TrackListLayoutMetrics.primarySecondaryTextSpacing)
        titleTrailingToDurationConstraint = titleField.trailingAnchor.constraint(lessThanOrEqualTo: durationField.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap)
        titleTrailingToArtistConstraint = titleField.trailingAnchor.constraint(lessThanOrEqualTo: artistField.leadingAnchor, constant: -16)
        artistTrailingToAlbumConstraint = artistField.trailingAnchor.constraint(lessThanOrEqualTo: albumField.leadingAnchor, constant: -16)
        artistTrailingToDurationConstraint = artistField.trailingAnchor.constraint(lessThanOrEqualTo: durationField.leadingAnchor, constant: -16)
        albumTrailingToDurationConstraint = albumField.trailingAnchor.constraint(lessThanOrEqualTo: durationField.leadingAnchor, constant: -16)
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

            titleField.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: TrackListLayoutMetrics.rowInterItemSpacing),
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
            durationField.widthAnchor.constraint(greaterThanOrEqualToConstant: TrackListLayoutMetrics.durationMinimumWidth),

            downloadImageView.trailingAnchor.constraint(equalTo: durationField.leadingAnchor, constant: -TrackListLayoutMetrics.rowTightAccessoryGap),
            downloadImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension),
            downloadImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.downloadIndicatorDimension),

            playingImageView.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -TrackListLayoutMetrics.rowAccessoryGap),
            playingImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingImageView.widthAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension),
            playingImageView.heightAnchor.constraint(equalToConstant: TrackListLayoutMetrics.playingIndicatorDimension)
        ])
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
    static let track = NSUserInterfaceItemIdentifier("SongsTrackListHost.TrackColumn")
    static let trackRow = NSUserInterfaceItemIdentifier("SongsTrackListHost.TrackRow")
    static let sectionHeader = NSUserInterfaceItemIdentifier("SongsTrackListHost.SectionHeader")
    static let bottomSpacer = NSUserInterfaceItemIdentifier("SongsTrackListHost.BottomSpacer")
}
#endif
