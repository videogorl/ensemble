import Foundation
import EnsemblePersistence

#if !os(macOS)
import Intents

public protocol SiriMediaUserContextManagerProtocol: Sendable {
    /// Updates Siri's media user context with current library statistics
    func updateMediaUserContext() async
}

@MainActor
public final class SiriMediaUserContextManager: SiriMediaUserContextManagerProtocol {
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let notificationCenter: NotificationCenter
    private let enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider?
    private var observerToken: NSObjectProtocol?
    // Track last published count to skip duplicate updates
    private var lastPublishedItemCount: Int?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        notificationCenter: NotificationCenter = .default,
        enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.notificationCenter = notificationCenter
        self.enabledSourceKeysProvider = enabledSourceKeysProvider
        
        // Listen for sync completion notifications to update context automatically
        observerToken = notificationCenter.addObserver(
            forName: SiriMediaIndexNotifications.rebuildRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.updateMediaUserContext()
            }
        }
    }
    
    deinit {
        if let observerToken {
            notificationCenter.removeObserver(observerToken)
        }
    }
    
    public func updateMediaUserContext() async {
        do {
            let enabledLibrarySourceKeys = enabledSourceKeysProvider?()
            let playlistSourceKeys = enabledLibrarySourceKeys.map {
                SystemMediaSourceScope.playlistSourceKeys(forEnabledLibraryKeys: $0)
            }

            // Gather library statistics
            let trackCount = try await libraryRepository.fetchTracks()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .count
            let albumCount = try await libraryRepository.fetchAlbums()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .count
            let artistCount = try await libraryRepository.fetchArtists()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: enabledLibrarySourceKeys) }
                .count
            let playlistCount = try await playlistRepository.fetchPlaylists()
                .filter { SystemMediaSourceScope.allows($0.sourceCompositeKey, within: playlistSourceKeys) }
                .count
            let totalItems = trackCount + albumCount + artistCount + playlistCount

            // Skip if the count hasn't changed since last publish
            guard totalItems != lastPublishedItemCount else {
                EnsembleLogger.debug("🎯 INMediaUserContext unchanged (\(totalItems) items) — skipping")
                return
            }

            // Create and configure media user context
            let context = INMediaUserContext()
            context.numberOfLibraryItems = totalItems
            context.subscriptionStatus = .unknown

            // Share context with Siri
            context.becomeCurrent()
            lastPublishedItemCount = totalItems

            EnsembleLogger.debug("🎯 Updated INMediaUserContext: \(totalItems) items (\(trackCount) tracks, \(albumCount) albums, \(artistCount) artists, \(playlistCount) playlists), status=unknown")
        } catch {
            EnsembleLogger.debug("⚠️ Failed to update INMediaUserContext: \(error.localizedDescription)")
        }
    }
}

#else

// Stub implementation for macOS (Intents not available)
public protocol SiriMediaUserContextManagerProtocol: Sendable {
    func updateMediaUserContext() async
}

@MainActor
public final class SiriMediaUserContextManager: SiriMediaUserContextManagerProtocol {
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider?
    
    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        notificationCenter: NotificationCenter = .default,
        enabledSourceKeysProvider: SystemMediaEnabledSourceKeysProvider? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.enabledSourceKeysProvider = enabledSourceKeysProvider
    }
    
    public func updateMediaUserContext() async {
        // No-op on macOS
    }
}

#endif
