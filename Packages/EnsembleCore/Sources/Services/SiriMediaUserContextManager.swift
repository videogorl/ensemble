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
    private var observerToken: NSObjectProtocol?
    // Track last published count to skip duplicate updates
    private var lastPublishedItemCount: Int?

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        notificationCenter: NotificationCenter = .default
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.notificationCenter = notificationCenter
        
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
            // Gather library statistics
            let trackCount = try await libraryRepository.fetchTracks().count
            let albumCount = try await libraryRepository.fetchAlbums().count
            let playlistCount = try await playlistRepository.fetchPlaylists().count
            let totalItems = trackCount + albumCount + playlistCount

            // Skip if the count hasn't changed since last publish
            guard totalItems != lastPublishedItemCount else {
                EnsembleLogger.debug("🎯 INMediaUserContext unchanged (\(totalItems) items) — skipping")
                return
            }

            // Determine subscription status based on whether user has content
            let subscriptionStatus: INMediaUserContext.SubscriptionStatus = totalItems > 0 ? .subscribed : .notSubscribed

            // Create and configure media user context
            let context = INMediaUserContext()
            context.numberOfLibraryItems = totalItems
            context.subscriptionStatus = subscriptionStatus

            // Share context with Siri
            context.becomeCurrent()
            lastPublishedItemCount = totalItems

            EnsembleLogger.debug("🎯 Updated INMediaUserContext: \(totalItems) items (\(trackCount) tracks, \(albumCount) albums, \(playlistCount) playlists), status=\(subscriptionStatus.rawValue)")
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
    
    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        notificationCenter: NotificationCenter = .default
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
    }
    
    public func updateMediaUserContext() async {
        // No-op on macOS
    }
}

#endif
