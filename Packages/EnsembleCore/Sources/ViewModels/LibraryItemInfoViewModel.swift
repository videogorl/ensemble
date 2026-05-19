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
    @Published public private(set) var aggregateDuration: TimeInterval?
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
        async let duration = loadAggregateDuration()

        let resolvedFileInfo = await fileInfo
        let resolvedDuration = await duration

        if originalFileInfo != resolvedFileInfo {
            originalFileInfo = resolvedFileInfo
        }
        if aggregateDuration != resolvedDuration {
            aggregateDuration = resolvedDuration
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

    private func loadAggregateDuration() async -> TimeInterval? {
        switch request {
        case .track(let track):
            return track.duration > 0 ? track.duration : nil
        case .album(let album):
            guard let sourceKey = album.sourceCompositeKey else { return nil }
            let tracks = try? await libraryRepository.fetchTracks(
                forAlbum: album.id,
                sourceCompositeKey: sourceKey
            )
            let duration = tracks?.reduce(TimeInterval(0)) { $0 + TimeInterval($1.duration) } ?? 0
            return duration > 0 ? duration : nil
        case .playlist(let playlist):
            guard let cdPlaylist = try? await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) else {
                return playlist.duration > 0 ? playlist.duration : nil
            }
            let duration = cdPlaylist.tracksArray.reduce(TimeInterval(0)) { $0 + TimeInterval($1.duration) }
            return duration > 0 ? duration : (playlist.duration > 0 ? playlist.duration : nil)
        }
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
