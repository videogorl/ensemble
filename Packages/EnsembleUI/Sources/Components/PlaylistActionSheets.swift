import EnsembleCore
import SwiftUI

public struct PlaylistPickerSheet: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let tracks: [Track]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var inferredServerSourceKey: String?
    @State private var isSubmitting = false
    @State private var searchText = ""

    public init(nowPlayingVM: NowPlayingViewModel, tracks: [Track], title: String = "Add to Playlist") {
        self.nowPlayingVM = nowPlayingVM
        self.tracks = tracks
        self.title = title
    }

    public var body: some View {
        NavigationView {
            List {
                Section("Playlists") {
                    if isLoading {
                        ProgressView("Loading playlists...")
                    } else if compatibleTrackCountForSelectedServer == 0 {
                        Text("No compatible tracks are available for playlist updates.")
                            .foregroundColor(.secondary)
                    } else if filteredPlaylists.isEmpty {
                        Text("No playlists found.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredPlaylists) { playlist in
                            Button {
                                Task { await addToPlaylist(playlist) }
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(playlist: playlist, size: .tiny, cornerRadius: 4)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.title)
                                        Text("\(playlist.trackCount) songs")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                            }
                            .disabled(
                                isSubmitting ||
                                nowPlayingVM.isPlaylistMutationInProgress ||
                                nowPlayingVM.compatibleTrackCount(tracks, for: playlist) == 0
                            )
                        }
                    }
                }

                if shouldShowCreateAction {
                    Section {
                        Button {
                            Task { await createPlaylist(named: newPlaylistName) }
                        } label: {
                            Label("Add new playlist: \"\(newPlaylistName)\"", systemImage: "plus.circle")
                        }
                        .disabled(
                            isSubmitting ||
                            nowPlayingVM.isPlaylistMutationInProgress ||
                            inferredServerSourceKey == nil ||
                            compatibleTrackCountForSelectedServer == 0
                        )
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Find or create playlist")
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                if inferredServerSourceKey == nil {
                    inferredServerSourceKey = await nowPlayingVM.resolveDefaultPlaylistServerSourceKey(for: tracks)
                    print("🎵 PlaylistPicker inferred server source: \(inferredServerSourceKey ?? "nil"), tracks: \(tracks.count)")
                }
                await loadPlaylists()
            }
            .overlay {
                if isSubmitting {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView("Updating playlist...")
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var filteredPlaylists: [Playlist] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return playlists }
        let lower = trimmed.lowercased()
        return playlists.filter { $0.title.lowercased().contains(lower) }
    }

    private var newPlaylistName: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExactNameMatch: Bool {
        let name = newPlaylistName.lowercased()
        guard !name.isEmpty else { return false }
        return playlists.contains { $0.title.lowercased() == name }
    }

    private var shouldShowCreateAction: Bool {
        !newPlaylistName.isEmpty && !hasExactNameMatch
    }

    private var compatibleTrackCountForSelectedServer: Int {
        guard !tracks.isEmpty else { return 0 }
        // If server source is still unknown, avoid false "no compatible tracks" state.
        guard inferredServerSourceKey != nil else { return tracks.count }
        return nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: inferredServerSourceKey)
    }

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await nowPlayingVM.loadPlaylists(forServerSourceKey: inferredServerSourceKey)
                .filter { !$0.isSmart }
                .sorted { lhs, rhs in
                    (lhs.dateModified ?? .distantPast) > (rhs.dateModified ?? .distantPast)
                }
        } catch {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "wifi.exclamationmark",
                    title: "Unable to load playlists",
                    message: error.localizedDescription,
                    action: ToastAction(title: "Retry") {
                        Task { await loadPlaylists() }
                    },
                    isPersistent: true,
                    dedupeKey: "playlist-load-error"
                )
            )
        }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard !isSubmitting, !nowPlayingVM.isPlaylistMutationInProgress else { return }
        let compatibleTracks = nowPlayingVM.tracks(tracks, compatibleWithServerSourceKey: playlist.sourceCompositeKey)
        guard !compatibleTracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "Playlist update skipped",
                    message: PlaylistMutationError.emptySelection.localizedDescription,
                    dedupeKey: "playlist-empty-selection"
                )
            )
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await nowPlayingVM.addTracks(compatibleTracks, to: playlist)
            dismiss()
        } catch {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "xmark.octagon.fill",
                    title: "Could not add to playlist",
                    message: error.localizedDescription,
                    action: ToastAction(title: "Retry") {
                        Task { await addToPlaylist(playlist) }
                    },
                    isPersistent: true,
                    dedupeKey: "playlist-add-error-\(playlist.id)"
                )
            )
        }
    }

    private func createPlaylist(named name: String) async {
        guard let inferredServerSourceKey else { return }
        let compatibleTracks = nowPlayingVM.tracks(tracks, compatibleWithServerSourceKey: inferredServerSourceKey)
        guard !compatibleTracks.isEmpty else {
            deps.toastCenter.show(
                ToastPayload(
                    style: .warning,
                    iconSystemName: "exclamationmark.triangle.fill",
                    title: "Playlist creation skipped",
                    message: PlaylistMutationError.emptySelection.localizedDescription,
                    dedupeKey: "playlist-create-empty-selection"
                )
            )
            return
        }
        guard !isSubmitting, !nowPlayingVM.isPlaylistMutationInProgress else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await nowPlayingVM.createPlaylist(
                title: name,
                tracks: compatibleTracks,
                serverSourceKey: inferredServerSourceKey
            )
            dismiss()
        } catch {
            deps.toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "xmark.octagon.fill",
                    title: "Could not create playlist",
                    message: error.localizedDescription,
                    action: ToastAction(title: "Retry") {
                        Task { await createPlaylist(named: name) }
                    },
                    isPersistent: true,
                    dedupeKey: "playlist-create-error-\(name.lowercased())"
                )
            )
        }
    }
}
