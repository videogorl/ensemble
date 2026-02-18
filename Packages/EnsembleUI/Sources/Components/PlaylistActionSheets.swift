import EnsembleCore
import SwiftUI

public struct PlaylistPickerSheet: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let tracks: [Track]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var selectedServerSourceKey: String?
    @State private var errorMessage: String?
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
                if shouldShowServerPicker {
                    Section("Server") {
                        Picker("Server", selection: Binding(
                            get: { selectedServerSourceKey ?? "" },
                            set: { selectedServerSourceKey = $0.isEmpty ? nil : $0 }
                        )) {
                            ForEach(serverOptions) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(isSubmitting || nowPlayingVM.isPlaylistMutationInProgress)
                    }
                }

                Section("Playlists") {
                    if isLoading {
                        ProgressView("Loading playlists...")
                    } else if compatibleTrackCountForSelectedServer == 0 {
                        Text("No compatible tracks for this server.")
                            .foregroundColor(.secondary)
                    } else if filteredPlaylists.isEmpty {
                        Text("No playlists found for this server.")
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
                            selectedServerSourceKey == nil ||
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
            .alert("Playlist Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { _ in errorMessage = nil }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if selectedServerSourceKey == nil {
                    let preferred = nowPlayingVM.defaultPlaylistServerSourceKey(for: tracks)
                    if let preferred,
                       nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: preferred) > 0 {
                        selectedServerSourceKey = preferred
                    } else if let compatible = serverOptions.first(where: {
                        nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: $0.id) > 0
                    }) {
                        selectedServerSourceKey = compatible.id
                    } else {
                        selectedServerSourceKey = serverOptions.first?.id
                    }
                }
                await loadPlaylists()
            }
            .onChange(of: selectedServerSourceKey) { _ in
                Task { await loadPlaylists() }
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

    private var serverOptions: [PlaylistServerOption] {
        nowPlayingVM.playlistServerOptions()
    }

    private var shouldShowServerPicker: Bool {
        serverOptions.count > 1
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
        nowPlayingVM.compatibleTrackCount(tracks, forServerSourceKey: selectedServerSourceKey)
    }

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await nowPlayingVM.loadPlaylists(forServerSourceKey: selectedServerSourceKey)
                .filter { !$0.isSmart }
                .sorted { lhs, rhs in
                    (lhs.dateModified ?? .distantPast) > (rhs.dateModified ?? .distantPast)
                }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard !isSubmitting, !nowPlayingVM.isPlaylistMutationInProgress else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await nowPlayingVM.addTracks(tracks, to: playlist)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createPlaylist(named name: String) async {
        guard let selectedServerSourceKey else { return }
        guard !isSubmitting, !nowPlayingVM.isPlaylistMutationInProgress else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await nowPlayingVM.createPlaylist(
                title: name,
                tracks: tracks,
                serverSourceKey: selectedServerSourceKey
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
