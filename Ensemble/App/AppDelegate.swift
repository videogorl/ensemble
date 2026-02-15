import AVFoundation
import Intents
import UIKit
import EnsembleCore
import EnsemblePersistence

class AppDelegate: NSObject, UIApplicationDelegate {

    // MARK: - Siri Intent Handling

    /// Handles Siri media intents when the app is launched or resumed
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        handleSiriIntent(from: userActivity)
        return true
    }

    /// Process the Siri intent and trigger playback
    func handleSiriIntent(from userActivity: NSUserActivity) {
        guard userActivity.activityType == NSStringFromClass(INPlayMediaIntent.self),
              let intent = userActivity.interaction?.intent as? INPlayMediaIntent else {
            print("AppDelegate: Not a play media intent")
            return
        }

        // Extract media item identifier (format: "type:ratingKey")
        guard let mediaItem = intent.mediaItems?.first,
              let identifier = mediaItem.identifier else {
            print("AppDelegate: No media item identifier in intent")
            return
        }

        let playShuffled = intent.playShuffled ?? false
        print("AppDelegate: Siri intent received - identifier: \(identifier), shuffle: \(playShuffled)")

        // Parse identifier (format: "type:ratingKey")
        let components = identifier.split(separator: ":", maxSplits: 1)
        guard components.count == 2 else {
            print("AppDelegate: Invalid identifier format: \(identifier)")
            return
        }

        let type = String(components[0])
        let ratingKey = String(components[1])

        Task { @MainActor in
            await handlePlaybackRequest(type: type, ratingKey: ratingKey, shuffle: playShuffled)
        }
    }

    /// Fetch tracks and trigger playback based on media type
    @MainActor
    private func handlePlaybackRequest(type: String, ratingKey: String, shuffle: Bool) async {
        let playbackService = DependencyContainer.shared.playbackService
        let libraryRepository = DependencyContainer.shared.libraryRepository
        let playlistRepository = DependencyContainer.shared.playlistRepository

        do {
            var tracks: [Track] = []

            switch type {
            case "artist":
                // Play all tracks by this artist
                let cdTracks = try await libraryRepository.fetchTracks(forArtist: ratingKey)
                tracks = cdTracks.map { Track(from: $0) }
                print("AppDelegate: Found \(tracks.count) tracks for artist \(ratingKey)")

            case "album":
                // Play album tracks
                let cdTracks = try await libraryRepository.fetchTracks(forAlbum: ratingKey)
                tracks = cdTracks.map { Track(from: $0) }
                print("AppDelegate: Found \(tracks.count) tracks for album \(ratingKey)")

            case "playlist":
                // Play playlist tracks
                if let playlist = try await playlistRepository.fetchPlaylist(ratingKey: ratingKey) {
                    tracks = playlist.tracksArray.map { Track(from: $0) }
                    print("AppDelegate: Found \(tracks.count) tracks for playlist \(ratingKey)")
                }

            case "track":
                // Play single track
                if let cdTrack = try await libraryRepository.fetchTrack(ratingKey: ratingKey) {
                    tracks = [Track(from: cdTrack)]
                    print("AppDelegate: Found track \(ratingKey)")
                }

            default:
                print("AppDelegate: Unknown media type: \(type)")
                return
            }

            guard !tracks.isEmpty else {
                print("AppDelegate: No tracks found for \(type):\(ratingKey)")
                return
            }

            // Trigger playback
            if shuffle {
                await playbackService.shufflePlay(tracks: tracks)
            } else {
                await playbackService.play(tracks: tracks, startingAt: 0)
            }

            print("AppDelegate: Started playback of \(tracks.count) tracks (shuffle: \(shuffle))")

        } catch {
            print("AppDelegate: Error handling Siri playback request: \(error)")
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("📱 AppDelegate: didFinishLaunching at \(Date())")
        
        // Configure audio session for background playback
        configureAudioSession()
        
        // Start network monitoring immediately (non-blocking)
        // Network monitor will publish initial state asynchronously
        Task.detached(priority: .utility) {
            await MainActor.run {
                print("📱 AppDelegate: Starting network monitor at \(Date())")
                DependencyContainer.shared.networkMonitor.startMonitoring()
                print("📱 AppDelegate: Network monitor started at \(Date())")
            }
        }
        
        // Restore playback state after network monitor has had time to detect connectivity
        // This prevents false "offline" errors during startup
        Task.detached(priority: .utility) {
            print("📱 AppDelegate: Waiting for network monitor to initialize...")
            
            // Wait for network monitor to report a non-Unknown state
            let networkMonitor = await MainActor.run { DependencyContainer.shared.networkMonitor }
            var attempts = 0
            let maxAttempts = 20 // 2 seconds max wait
            
            while attempts < maxAttempts {
                let state = await MainActor.run { networkMonitor.networkState }
                if state != .unknown {
                    print("📱 AppDelegate: Network state detected: \(state)")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                attempts += 1
            }
            
            // Small additional delay to ensure connections are stable
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            print("📱 AppDelegate: Getting playbackService...")
            let playbackService = await MainActor.run {
                DependencyContainer.shared.playbackService
            }
            print("📱 AppDelegate: Calling restorePlaybackState()...")
            await playbackService.restorePlaybackState()
            print("📱 AppDelegate: Playback state restoration complete")
        }
        
        print("📱 AppDelegate: didFinishLaunching returning at \(Date())")
        return true
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Handle background download completion
        completionHandler()
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Stop network monitoring to save battery
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.stopMonitoring()
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        // Resume network monitoring when app returns to foreground
        Task { @MainActor in
            DependencyContainer.shared.networkMonitor.startMonitoring()

            // Proactively check server health and update connections
            // (network monitor will also trigger this, but doing it immediately ensures faster failover)
            await DependencyContainer.shared.serverHealthChecker.checkAllServers()
            await DependencyContainer.shared.syncCoordinator.refreshAPIClientConnections()
        }
    }
}
