import EnsembleAPI
import Foundation

/// View model for the library Get Info panel.
@MainActor
public final class LibraryItemInfoViewModel: ObservableObject {
    public struct SourceContext: Equatable, Sendable {
        public let serverName: String?
        public let libraryName: String?
    }

    @Published public private(set) var sourceContext = SourceContext(serverName: nil, libraryName: nil)
    @Published public private(set) var originalFileInfo: AudioFileInfo?
    @Published public private(set) var originalFolderPath: String?
    @Published public private(set) var aggregateDuration: TimeInterval?
    @Published public private(set) var aggregateTrackCount: Int?
    @Published public private(set) var isLoading = false

    public let request: LibraryItemInfoRequest

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let accountManager: AccountManager

    public init(
        request: LibraryItemInfoRequest,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        accountManager: AccountManager
    ) {
        self.request = request
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.accountManager = accountManager
        self.sourceContext = Self.resolveSourceContext(
            sourceCompositeKey: request.sourceCompositeKey,
            accountManager: accountManager
        )
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let fileInfo = loadOriginalFileInfo()
        async let aggregate = loadAggregateMetadata()

        let resolvedFileInfo = await fileInfo
        let resolvedFolderPath: String?
        switch request {
        case .track:
            resolvedFolderPath = nil
        case .album:
            resolvedFolderPath = await loadAlbumOriginalFolderPath()
        case .playlist:
            resolvedFolderPath = nil
        }
        let resolvedAggregate = await aggregate

        if originalFileInfo != resolvedFileInfo {
            originalFileInfo = resolvedFileInfo
        }
        if originalFolderPath != resolvedFolderPath {
            originalFolderPath = resolvedFolderPath
        }
        if aggregateDuration != resolvedAggregate.duration {
            aggregateDuration = resolvedAggregate.duration
        }
        if aggregateTrackCount != resolvedAggregate.trackCount {
            aggregateTrackCount = resolvedAggregate.trackCount
        }
    }

    private func loadOriginalFileInfo() async -> AudioFileInfo? {
        guard case .track(let track) = request,
              let apiClient = syncCoordinator.apiClient(for: track.sourceCompositeKey)
        else {
            return nil
        }

        do {
            guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else { return nil }
            return AudioFileInfo(from: plexTrack)
        } catch {
            EnsembleLogger.debug("Failed to fetch Get Info file metadata: \(error)")
            return nil
        }
    }

    private func loadAlbumOriginalFolderPath() async -> String? {
        guard case .album(let album) = request,
              let sourceKey = album.sourceCompositeKey,
              let apiClient = syncCoordinator.apiClient(for: sourceKey)
        else {
            return nil
        }

        do {
            let tracks = try await apiClient.getAlbumTracks(albumKey: album.id)
            return Self.albumFolderPath(from: tracks)
        } catch {
            EnsembleLogger.debug("Failed to fetch Get Info album folder path: \(error)")
            return nil
        }
    }

    private func loadAggregateMetadata() async -> AggregateMetadata {
        switch request {
        case .track(let track):
            return AggregateMetadata(
                duration: track.duration > 0 ? track.duration : nil,
                trackCount: nil
            )
        case .album(let album):
            guard let sourceKey = album.sourceCompositeKey else {
                return AggregateMetadata(duration: nil, trackCount: nil)
            }
            let tracks = try? await libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceKey
            )
            let duration = tracks?.reduce(TimeInterval(0)) {
                $0 + Self.persistedTrackDurationSeconds($1.duration)
            } ?? 0
            return AggregateMetadata(
                duration: duration > 0 ? duration : nil,
                trackCount: tracks?.count
            )
        case .playlist(let playlist):
            guard let cdPlaylist = try? await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) else {
                return AggregateMetadata(
                    duration: playlist.duration > 0 ? playlist.duration : nil,
                    trackCount: nil
                )
            }
            let duration = cdPlaylist.tracksArray.reduce(TimeInterval(0)) {
                $0 + Self.persistedTrackDurationSeconds($1.duration)
            }
            return AggregateMetadata(
                duration: duration > 0 ? duration : (playlist.duration > 0 ? playlist.duration : nil),
                trackCount: nil
            )
        }
    }

    public static func resolvedAlbumTrackCount(albumTrackCount: Int, fetchedTrackCount: Int?) -> Int {
        fetchedTrackCount ?? albumTrackCount
    }

    static func persistedTrackDurationSeconds(_ durationMilliseconds: Int64) -> TimeInterval {
        TimeInterval(durationMilliseconds) / 1000.0
    }

    static func filePaths(from tracks: [PlexTrack]) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []

        for track in tracks {
            guard let path = track.media?.first?.part?.first?.file,
                  !path.isEmpty,
                  seen.insert(path).inserted
            else {
                continue
            }
            paths.append(path)
        }

        return paths
    }

    static func albumFolderPath(from tracks: [PlexTrack]) -> String? {
        let directoryComponents = filePaths(from: tracks)
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().pathComponents }

        guard var commonComponents = directoryComponents.first else { return nil }

        for components in directoryComponents.dropFirst() {
            commonComponents = Array(
                zip(commonComponents, components)
                    .prefix { $0 == $1 }
                    .map(\.0)
            )
            if commonComponents.isEmpty {
                return nil
            }
        }

        return NSString.path(withComponents: commonComponents)
    }

    private static func resolveSourceContext(
        sourceCompositeKey: String?,
        accountManager: AccountManager
    ) -> SourceContext {
        guard let key = sourceCompositeKey else {
            return SourceContext(serverName: nil, libraryName: nil)
        }

        let components = key.split(separator: ":").map(String.init)
        guard components.count >= 3 else {
            return SourceContext(serverName: nil, libraryName: nil)
        }

        let accountId = components[1]
        let serverId = components[2]
        let libraryId = components.count >= 4 ? components[3] : nil

        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }),
              let server = account.servers.first(where: { $0.id == serverId })
        else {
            return SourceContext(serverName: nil, libraryName: nil)
        }

        let libraryName = libraryId.flatMap { id in
            server.libraries.first(where: { $0.id == id })?.title
        }

        return SourceContext(serverName: server.name, libraryName: libraryName)
    }
}

private struct AggregateMetadata: Equatable {
    let duration: TimeInterval?
    let trackCount: Int?
}
