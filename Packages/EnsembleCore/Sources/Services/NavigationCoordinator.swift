import EnsembleSiriShared
import SwiftUI
import Combine

/// Centralized navigation coordinator for handling deep links and cross-tab navigation
@MainActor
public final class NavigationCoordinator: ObservableObject {
    private static weak var activeAuxiliaryCommandCoordinator: NavigationCoordinator?
    private static weak var activeSceneCoordinator: NavigationCoordinator?
    private static var pendingExternalSearchDestination: Destination?

    public enum AuxiliaryPresentation: String, Identifiable {
        case profile
        case downloads

        public var id: String { rawValue }

        public var windowID: String {
            switch self {
            case .profile:
                return "profile-window"
            case .downloads:
                return "downloads-window"
            }
        }
    }

    public struct AuxiliaryWindowRequest: Identifiable, Equatable {
        public let id = UUID()
        public let destination: AuxiliaryPresentation

        public init(destination: AuxiliaryPresentation) {
            self.destination = destination
        }
    }

    /// Represents a navigation destination using IDs for hashability and deep linking
    public enum Destination: Hashable {
        case displayArtist(id: String)
        case displayGenre(id: String)
        case artistDetail(Artist)
        case artist(id: String, sourceKey: String? = nil)
        case album(id: String, sourceKey: String? = nil)
        case albumDetail(Album)
        case playlist(id: String, sourceKey: String?)
        case playlistDetail(Playlist)
        case mergedPlaylist(title: String, isSmart: Bool)
        case moodTracks(mood: Mood)
        case view(TabItem) // For pushing library views from the More menu

        var journeyLogDescription: String {
            switch self {
            case .displayArtist, .artistDetail, .artist:
                return "artist"
            case .displayGenre:
                return "genre"
            case .album, .albumDetail:
                return "album"
            case .playlist, .playlistDetail:
                return "playlist"
            case .mergedPlaylist(_, let isSmart):
                return isSmart ? "smartPlaylist" : "playlist"
            case .moodTracks:
                return "moodTracks"
            case .view(let tab):
                return "view(\(tab.rawValue))"
            }
        }
    }
    
    /// The currently selected tab
    @Published public var selectedTab: TabItem = .home {
        didSet {
            guard oldValue != selectedTab else { return }
            logJourney("tabChanged from=\(oldValue.rawValue) to=\(selectedTab.rawValue)")
        }
    }

    /// Visible tabs in the tab bar (synced from MainTabView to enable fallback logic)
    public var visibleTabs: [TabItem] = [.home, .artists, .playlists, .search]

    /// Whether hidden tab destinations should route through the More tab path.
    public var routesHiddenTabsThroughMore = false

    // Per-tab navigation paths (strictly typed as [Destination] for iOS 15+ compatibility)
    @Published public var homePath: [Destination] = []
    @Published public var songsPath: [Destination] = []
    @Published public var artistsPath: [Destination] = []
    @Published public var albumsPath: [Destination] = []
    @Published public var genresPath: [Destination] = []
    @Published public var playlistsPath: [Destination] = []
    @Published public var favoritesPath: [Destination] = []
    @Published public var searchPath: [Destination] = []
    @Published public var downloadsPath: [Destination] = []
    @Published public var settingsPath: [Destination] = []
    
    /// Drives the "Add Plex Account" sheet from a stable root-level view
    /// (MainTabView / SidebarView) so it survives TabView content recreation.
    @Published public var showingAddAccount = false
    @Published public var activeAuxiliaryPresentation: AuxiliaryPresentation?
    @Published public var auxiliaryWindowRequest: AuxiliaryWindowRequest?
    @Published public private(set) var routeTransitionTabs: Set<TabItem> = []

    /// For NowPlaying flow: pending navigation to execute after sheet dismissal
    public struct PendingNavigation {
        public let tab: TabItem
        public let destination: Destination
        
        public init(tab: TabItem, destination: Destination) {
            self.tab = tab
            self.destination = destination
        }
    }
    
    @Published public var pendingNavigation: PendingNavigation?

    private weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    private var navigationInteractionGeneration = 0
    private let navigationInteractionDurationNanoseconds: UInt64

    public init(
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil,
        navigationInteractionDurationNanoseconds: UInt64 = 700_000_000
    ) {
        self.foregroundWorkScheduler = foregroundWorkScheduler
        self.navigationInteractionDurationNanoseconds = navigationInteractionDurationNanoseconds
    }

    public nonisolated static func targetTab(for destination: Destination) -> TabItem {
        switch destination {
        case .displayArtist, .artistDetail:
            return .artists
        case .displayGenre:
            return .genres
        case .artist:
            return .artists
        case .album, .albumDetail:
            return .albums
        case .playlist, .playlistDetail, .mergedPlaylist:
            return .playlists
        case .moodTracks:
            return .home
        case .view(let tab):
            return tab
        }
    }

    public nonisolated static func systemMediaDestination(
        fromSourceScopedIdentifier identifier: String
    ) -> Destination? {
        guard let components = SystemMediaReference.components(fromSourceScopedIdentifier: identifier) else {
            return nil
        }

        switch components.kind {
        case .artist:
            return .artist(id: components.id, sourceKey: components.sourceCompositeKey)
        case .album:
            return .album(id: components.id, sourceKey: components.sourceCompositeKey)
        case .playlist:
            return .playlist(id: components.id, sourceKey: components.sourceCompositeKey)
        case .track:
            return .view(.songs)
        }
    }

    public static func setActiveAuxiliaryCommandCoordinator(_ coordinator: NavigationCoordinator) {
        activeAuxiliaryCommandCoordinator = coordinator
    }

    public static func clearActiveAuxiliaryCommandCoordinator(_ coordinator: NavigationCoordinator) {
        guard activeAuxiliaryCommandCoordinator === coordinator else { return }
        activeAuxiliaryCommandCoordinator = nil
    }

    public static func setActiveSceneCoordinator(_ coordinator: NavigationCoordinator) {
        activeSceneCoordinator = coordinator

        guard let destination = pendingExternalSearchDestination else { return }
        pendingExternalSearchDestination = nil
        coordinator.navigateFromExternalSearch(to: destination)
        EnsembleLogger.info("SPOTLIGHT_APP: Applied pending Spotlight route to active scene")
    }

    public static func clearActiveSceneCoordinator(_ coordinator: NavigationCoordinator) {
        guard activeSceneCoordinator === coordinator else { return }
        activeSceneCoordinator = nil
    }

    public static func openProfileFromActiveScene(fallback: NavigationCoordinator) {
        (activeAuxiliaryCommandCoordinator ?? activeSceneCoordinator ?? fallback).openProfile()
    }

    @discardableResult
    public static func routeExternalSearchInActiveScene(to destination: Destination) -> Bool {
        guard let coordinator = activeSceneCoordinator ?? activeAuxiliaryCommandCoordinator else {
            pendingExternalSearchDestination = destination
            return false
        }

        coordinator.navigateFromExternalSearch(to: destination)
        return true
    }
    
    // MARK: - Navigation Methods
    
    /// Push a destination onto a specific tab's stack
    public func push(_ destination: Destination, in tab: TabItem) {
        // No-op if already viewing same item as last in stack
        guard path(for: tab).last != destination else { return }

        let previousDepth = path(for: tab).count
        switch tab {
        case .home: homePath.append(destination)
        case .songs: songsPath.append(destination)
        case .artists: artistsPath.append(destination)
        case .albums: albumsPath.append(destination)
        case .genres: genresPath.append(destination)
        case .playlists: playlistsPath.append(destination)
        case .favorites: favoritesPath.append(destination)
        case .search: searchPath.append(destination)
        case .downloads: downloadsPath.append(destination)
        case .settings: settingsPath.append(destination)
        }
        logJourney(
            "push tab=\(tab.rawValue) destination=\(destination.journeyLogDescription) depth=\(previousDepth)->\(previousDepth + 1)"
        )
    }

    public func beginRouteTransition(in tab: TabItem, durationNanoseconds: UInt64 = 700_000_000) {
        routeTransitionTabs.insert(tab)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            routeTransitionTabs.remove(tab)
        }
    }

    public func isRouteTransitionActive(for tab: TabItem) -> Bool {
        routeTransitionTabs.contains(tab)
    }

    public func pathSnapshot(for tab: TabItem) -> [Destination] {
        path(for: tab)
    }

    public func setPath(_ path: [Destination], for tab: TabItem) {
        let previousPath = self.path(for: tab)
        guard previousPath != path else { return }

        switch tab {
        case .home: homePath = path
        case .songs: songsPath = path
        case .artists: artistsPath = path
        case .albums: albumsPath = path
        case .genres: genresPath = path
        case .playlists: playlistsPath = path
        case .favorites: favoritesPath = path
        case .search: searchPath = path
        case .downloads: downloadsPath = path
        case .settings: settingsPath = path
        }
        logJourney(
            "setPath tab=\(tab.rawValue) depth=\(previousPath.count)->\(path.count) top=\(path.last?.journeyLogDescription ?? "root")"
        )
    }
    
    /// Pop to root for a specific tab
    public func popToRoot(tab: TabItem) {
        let previousDepth = path(for: tab).count
        guard previousDepth > 0 else { return }

        switch tab {
        case .home: homePath.removeAll()
        case .songs: songsPath.removeAll()
        case .artists: artistsPath.removeAll()
        case .albums: albumsPath.removeAll()
        case .genres: genresPath.removeAll()
        case .playlists: playlistsPath.removeAll()
        case .favorites: favoritesPath.removeAll()
        case .search: searchPath.removeAll()
        case .downloads: downloadsPath.removeAll()
        case .settings: settingsPath.removeAll()
        }
        logJourney("popToRoot tab=\(tab.rawValue) depth=\(previousDepth)->0")
    }
    
    /// Request navigation immediately (using current tab or fallback)
    public func navigate(to destination: Destination) {
        let targetTab = activeNavigationTab()
        logJourney("navigate targetTab=\(targetTab.rawValue) destination=\(destination.journeyLogDescription)")
        selectedTab = targetTab
        push(destination, in: targetTab)
    }

    /// Route external content selections to the destination's owning tab.
    public func navigateFromExternalSearch(to destination: Destination) {
        let targetTab = Self.targetTab(for: destination)
        logJourney("externalRoute targetTab=\(targetTab.rawValue) destination=\(destination.journeyLogDescription)")
        if shouldRouteExternalSearchThroughMore(targetTab: targetTab) {
            routeExternalSearchThroughMore(destination, targetTab: targetTab)
            return
        }

        popToRoot(tab: targetTab)
        selectedTab = targetTab

        guard case .view = destination else {
            push(destination, in: targetTab)
            return
        }
    }
    
    /// Request navigation from NowPlaying sheet (handles dismiss-then-navigate)
    /// Uses current tab (or first visible if currently in Search)
    public func navigateFromNowPlaying(to destination: Destination) {
        let targetTab = activeNavigationTab()
        logJourney("nowPlayingRoutePending targetTab=\(targetTab.rawValue) destination=\(destination.journeyLogDescription)")
        pendingNavigation = PendingNavigation(tab: targetTab, destination: destination)
    }
    
    /// Handle deep links by popping to root of the first visible tab and pushing the new destination
    public func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "ensemble" else { return false }
        
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        
        let type = components[0]
        let id = components[1]
        
        let destination: Destination
        switch type {
        case "artist":
            destination = .artist(id: id, sourceKey: nil)
        case "album":
            destination = .album(id: id, sourceKey: nil)
        case "playlist":
            destination = .playlist(id: id, sourceKey: nil)
        default:
            return false
        }
        
        // Deep links always go to the first visible tab
        let targetTab = visibleTabs.first ?? .home

        // Pop to root of the target tab first for a clean state
        popToRoot(tab: targetTab)

        // Switch tab and push
        selectedTab = targetTab
        push(destination, in: targetTab)
        
        return true
    }

    /// Open the profile sheet/window.
    public func openProfile() {
        requestAuxiliaryPresentation(.profile)
    }

    public func openDownloads() {
        requestAuxiliaryPresentation(.downloads)
    }

    public func dismissAuxiliaryPresentation() {
        activeAuxiliaryPresentation = nil
    }

    public func consumeAuxiliaryWindowRequest() {
        auxiliaryWindowRequest = nil
    }

    // MARK: - Helper Methods

    private func requestAuxiliaryPresentation(_ destination: AuxiliaryPresentation) {
        logJourney("auxiliaryPresentation destination=\(destination.rawValue)")
        activeAuxiliaryPresentation = destination
        auxiliaryWindowRequest = AuxiliaryWindowRequest(destination: destination)
    }

    private func logJourney(_ message: String) {
        markNavigationInteraction()
        EnsembleLogger.info("USER_JOURNEY: \(message)")
    }

    private func markNavigationInteraction() {
        guard let foregroundWorkScheduler else { return }

        navigationInteractionGeneration += 1
        let generation = navigationInteractionGeneration
        foregroundWorkScheduler.beginInteraction(.navigating)
        let durationNanoseconds = navigationInteractionDurationNanoseconds

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard let self else {
                foregroundWorkScheduler.endInteraction(.navigating)
                return
            }
            guard self.navigationInteractionGeneration == generation else { return }
            foregroundWorkScheduler.endInteraction(.navigating)
        }
    }

    private func activeNavigationTab() -> TabItem {
        if selectedTab == .search {
            return visibleTabs.first ?? .home
        }
        return selectedTab
    }

    private func shouldRouteExternalSearchThroughMore(targetTab: TabItem) -> Bool {
        routesHiddenTabsThroughMore &&
            targetTab != .settings &&
            !visibleTabs.contains(targetTab)
    }

    private func routeExternalSearchThroughMore(_ destination: Destination, targetTab: TabItem) {
        let path: [Destination]
        if case .view = destination {
            path = [.view(targetTab)]
        } else {
            path = [.view(targetTab), destination]
        }

        setPath([], for: targetTab)
        setPath(path, for: .settings)
        selectedTab = .settings
    }

    private func path(for tab: TabItem) -> [Destination] {
        switch tab {
        case .home: return homePath
        case .songs: return songsPath
        case .artists: return artistsPath
        case .albums: return albumsPath
        case .genres: return genresPath
        case .playlists: return playlistsPath
        case .favorites: return favoritesPath
        case .search: return searchPath
        case .downloads: return downloadsPath
        case .settings: return settingsPath
        }
    }
}
