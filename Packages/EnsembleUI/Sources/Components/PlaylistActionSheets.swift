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
    @State private var showCreateSheet = false
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    public init(nowPlayingVM: NowPlayingViewModel, tracks: [Track], title: String = "Add to Playlist") {
        self.nowPlayingVM = nowPlayingVM
        self.tracks = tracks
        self.title = title
    }

    public var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("New Playlist", systemImage: "plus.circle")
                    }
                    .disabled(isSubmitting)
                }

                if !serverOptions.isEmpty {
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
                        .disabled(isSubmitting)
                    }
                }

                Section("Playlists") {
                    if isLoading {
                        ProgressView("Loading playlists...")
                    } else if playlists.isEmpty {
                        Text("No playlists found for this server.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(playlists) { playlist in
                            Button {
                                Task { await addToPlaylist(playlist) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.title)
                                        Text("\(playlist.trackCount) songs")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if playlist.isSmart {
                                        Text("Smart")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(playlist.isSmart)
                            .disabled(isSubmitting)
                        }
                    }
                }
            }
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
                    selectedServerSourceKey = nowPlayingVM.defaultPlaylistServerSourceKey(for: tracks)
                }
                await loadPlaylists()
            }
            .onChange(of: selectedServerSourceKey) { _ in
                Task { await loadPlaylists() }
            }
            .sheet(isPresented: $showCreateSheet) {
                NewPlaylistSheet(
                    nowPlayingVM: nowPlayingVM,
                    tracks: tracks,
                    defaultServerSourceKey: selectedServerSourceKey
                )
            }
            .overlay {
                if isSubmitting {
                    ZStack {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                        ProgressView("Adding to playlist...")
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

    private func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await nowPlayingVM.loadPlaylists(forServerSourceKey: selectedServerSourceKey)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addToPlaylist(_ playlist: Playlist) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await nowPlayingVM.addTracks(tracks, to: playlist)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct NewPlaylistSheet: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let tracks: [Track]
    let defaultServerSourceKey: String?

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selectedServerSourceKey: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    public init(
        nowPlayingVM: NowPlayingViewModel,
        tracks: [Track],
        defaultServerSourceKey: String?
    ) {
        self.nowPlayingVM = nowPlayingVM
        self.tracks = tracks
        self.defaultServerSourceKey = defaultServerSourceKey
    }

    public var body: some View {
        NavigationView {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $title)
                }
                Section("Server") {
                    Picker("Server", selection: Binding(
                        get: { selectedServerSourceKey ?? "" },
                        set: { selectedServerSourceKey = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(nowPlayingVM.playlistServerOptions()) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
            }
            .navigationTitle("New Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createPlaylist() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedServerSourceKey == nil)
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
                    selectedServerSourceKey = defaultServerSourceKey ?? nowPlayingVM.defaultPlaylistServerSourceKey(for: tracks)
                }
            }
        }
    }

    private func createPlaylist() async {
        guard let selectedServerSourceKey else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            _ = try await nowPlayingVM.createPlaylist(
                title: title,
                tracks: tracks,
                serverSourceKey: selectedServerSourceKey
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
