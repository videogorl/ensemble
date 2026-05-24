import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class ExternalDeviceSyncService: ObservableObject {
    @Published public private(set) var devices: [ExternalDevice] = []
    @Published public private(set) var syncSummaries: [String: ExternalDeviceSyncSummary] = [:]
    @Published public private(set) var syncingDeviceIDs: Set<String> = []

    private let repository: ExternalDeviceSyncRepositoryProtocol
    private let discovery: IPodDeviceDiscovering
    private let adapter: IPodDatabaseAdapting
    private let mutationCoordinator: MutationCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let planner: ExternalDeviceSyncPlanner
    private var activeSnapshots: [String: IPodDeviceSnapshot] = [:]
    private var databaseAccessAvailable = false
    private var monitorTask: Task<Void, Never>?
    private var autoSyncedThisSession = Set<String>()

    public init(
        repository: ExternalDeviceSyncRepositoryProtocol,
        discovery: IPodDeviceDiscovering = MountedIPodDeviceDiscovery(),
        adapter: IPodDatabaseAdapting = ExternalIPodHelperAdapter(),
        mutationCoordinator: MutationCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        planner: ExternalDeviceSyncPlanner = ExternalDeviceSyncPlanner()
    ) {
        self.repository = repository
        self.discovery = discovery
        self.adapter = adapter
        self.mutationCoordinator = mutationCoordinator
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.planner = planner
    }

    deinit {
        monitorTask?.cancel()
    }

    public func startAutomaticMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refreshMountedDevices(syncDiscoveredDevices: true)
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    public func refreshMountedDevices(syncDiscoveredDevices: Bool = false) async {
        databaseAccessAvailable = await adapter.canAccessDatabase()
        guard databaseAccessAvailable else {
            activeSnapshots = [:]
            if !devices.isEmpty {
                devices = []
            }
            return
        }

        let snapshots = await discovery.discoverMountedDevices()
        activeSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.deviceID, $0) })

        for snapshot in snapshots {
            do {
                let supportMessage: String?
                let isSupported: Bool
                switch snapshot.supportState {
                case .supported:
                    supportMessage = nil
                    isSupported = true
                case .unsupported(let message):
                    supportMessage = message
                    isSupported = false
                }
                _ = try await repository.upsertDevice(
                    deviceID: snapshot.deviceID,
                    displayName: snapshot.name,
                    modelIdentifier: snapshot.modelIdentifier,
                    mountPath: snapshot.mountURL.path,
                    totalCapacity: snapshot.totalCapacity,
                    freeCapacity: snapshot.freeCapacity,
                    isSupported: isSupported,
                    supportMessage: supportMessage,
                    automaticSyncEnabled: nil
                )
            } catch {
                EnsembleLogger.debug("ExternalDeviceSyncService: failed to persist discovered device: \(error.localizedDescription)")
            }
        }

        await reloadDevices()

        guard syncDiscoveredDevices else { return }
        for device in devices where device.automaticSyncEnabled {
            guard !autoSyncedThisSession.contains(device.id),
                  case .supported = device.supportState,
                  activeSnapshots[device.id] != nil else {
                continue
            }
            autoSyncedThisSession.insert(device.id)
            Task { @MainActor [weak self] in
                await self?.syncDevice(id: device.id)
            }
        }
    }

    public func reloadDevices() async {
        guard databaseAccessAvailable else {
            if !devices.isEmpty {
                devices = []
            }
            return
        }

        do {
            let records = try await repository.fetchDevices()
            let activeDeviceIDs = Set(activeSnapshots.keys)
            let mapped = records
                .map(ExternalDevice.init(record:))
                .filter { activeDeviceIDs.contains($0.id) }
            if mapped != devices {
                devices = mapped
            }
        } catch {
            EnsembleLogger.debug("ExternalDeviceSyncService: failed to load devices: \(error.localizedDescription)")
        }
    }

    public func syncDevice(id deviceID: String) async {
        guard let snapshot = activeSnapshots[deviceID] else {
            syncSummaries[deviceID] = ExternalDeviceSyncSummary(
                status: "not-connected",
                message: "Connect the iPod to sync."
            )
            return
        }
        await syncDevice(snapshot)
    }

    private func syncDevice(_ snapshot: IPodDeviceSnapshot) async {
        guard !syncingDeviceIDs.contains(snapshot.deviceID) else { return }
        syncingDeviceIDs.insert(snapshot.deviceID)
        defer { syncingDeviceIDs.remove(snapshot.deviceID) }

        let startedAt = Date()
        do {
            let library = try await adapter.readLibrary(device: snapshot)
            let trackMaps = try await repository.fetchMaps(deviceID: snapshot.deviceID, kind: .track)
            let playlistMaps = try await repository.fetchMaps(deviceID: snapshot.deviceID, kind: .playlist)
            let importPlan = planner.planImport(
                snapshot: library,
                trackMaps: trackMaps,
                playlistMaps: playlistMaps
            )
            let importCounts = await applyImportPlan(importPlan)
            let exportSummary = try await adapter.commitAdditiveSync(device: snapshot)
            let summary = ExternalDeviceSyncSummary(
                status: exportSummary.status,
                importedRatings: importCounts.ratings,
                importedPlays: importCounts.plays,
                importedPlaylists: importCounts.playlists,
                exportedTracks: exportSummary.exportedTracks,
                exportedPlaylists: exportSummary.exportedPlaylists,
                discardedItems: importPlan.discardedItemCount + exportSummary.discardedItems,
                message: exportSummary.message
            )
            syncSummaries[snapshot.deviceID] = summary
            _ = try await repository.recordSyncRun(
                deviceID: snapshot.deviceID,
                startedAt: startedAt,
                finishedAt: Date(),
                status: summary.status,
                importedRatings: summary.importedRatings,
                importedPlays: summary.importedPlays,
                importedPlaylists: summary.importedPlaylists,
                exportedTracks: summary.exportedTracks,
                exportedPlaylists: summary.exportedPlaylists,
                discardedItems: summary.discardedItems,
                errorMessage: summary.message
            )
        } catch {
            let summary = ExternalDeviceSyncSummary(
                status: "blocked",
                discardedItems: 0,
                message: error.localizedDescription
            )
            syncSummaries[snapshot.deviceID] = summary
            _ = try? await repository.recordSyncRun(
                deviceID: snapshot.deviceID,
                startedAt: startedAt,
                finishedAt: Date(),
                status: summary.status,
                importedRatings: 0,
                importedPlays: 0,
                importedPlaylists: 0,
                exportedTracks: 0,
                exportedPlaylists: 0,
                discardedItems: 0,
                errorMessage: summary.message
            )
        }

        await reloadDevices()
    }

    private func applyImportPlan(_ plan: ExternalDeviceImportPlan) async -> (ratings: Int, plays: Int, playlists: Int) {
        var appliedRatings = 0
        var appliedPlays = 0
        var appliedPlaylists = 0

        for update in plan.ratingUpdates {
            guard let track = await fetchTrack(
                ratingKey: update.trackRatingKey,
                sourceCompositeKey: update.sourceCompositeKey
            ) else {
                continue
            }
            do {
                _ = try await mutationCoordinator.rateTrack(track, rating: update.plexRating)
                try await repository.updateImportCheckpoint(
                    mapID: update.mapID,
                    playCount: nil,
                    rating: update.checkpointRating
                )
                appliedRatings += 1
            } catch {
                EnsembleLogger.debug("ExternalDeviceSyncService: failed to import iPod rating: \(error.localizedDescription)")
            }
        }

        for delta in plan.playDeltas {
            guard let track = await fetchTrack(
                ratingKey: delta.trackRatingKey,
                sourceCompositeKey: delta.sourceCompositeKey
            ) else {
                continue
            }
            for _ in 0..<delta.delta {
                _ = await mutationCoordinator.scrobbleTrack(track)
                appliedPlays += 1
            }
            try? await repository.updateImportCheckpoint(
                mapID: delta.mapID,
                playCount: delta.checkpointPlayCount,
                rating: nil
            )
        }

        for update in plan.playlistUpdates {
            let tracks = await fetchTracks(update.trackReferences)
            guard !tracks.isEmpty else { continue }
            do {
                switch update.action {
                case .create(let title, let sourceCompositeKey):
                    _ = try await mutationCoordinator.createPlaylist(
                        title: title,
                        tracks: tracks,
                        serverSourceKey: sourceCompositeKey
                    )
                    appliedPlaylists += 1
                case .updateExisting(let playlistRatingKey, let sourceCompositeKey):
                    guard let playlist = await fetchPlaylist(
                        ratingKey: playlistRatingKey,
                        sourceCompositeKey: sourceCompositeKey
                    ) else {
                        continue
                    }
                    _ = try await mutationCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
                    appliedPlaylists += 1
                }
            } catch {
                EnsembleLogger.debug("ExternalDeviceSyncService: failed to import iPod playlist: \(error.localizedDescription)")
            }
        }

        return (appliedRatings, appliedPlays, appliedPlaylists)
    }

    private func fetchTrack(ratingKey: String, sourceCompositeKey: String) async -> Track? {
        do {
            guard let track = try await libraryRepository.fetchTrack(
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                return nil
            }
            return Track(from: track)
        } catch {
            EnsembleLogger.debug("ExternalDeviceSyncService: failed to resolve mapped track: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchTracks(_ references: [ExternalDeviceTrackReference]) async -> [Track] {
        var tracks: [Track] = []
        for reference in references {
            if let track = await fetchTrack(
                ratingKey: reference.ratingKey,
                sourceCompositeKey: reference.sourceCompositeKey
            ) {
                tracks.append(track)
            }
        }
        return tracks
    }

    private func fetchPlaylist(ratingKey: String, sourceCompositeKey: String) async -> Playlist? {
        do {
            guard let playlist = try await playlistRepository.fetchPlaylist(
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                return nil
            }
            return Playlist(from: playlist)
        } catch {
            EnsembleLogger.debug("ExternalDeviceSyncService: failed to resolve mapped playlist: \(error.localizedDescription)")
            return nil
        }
    }
}
