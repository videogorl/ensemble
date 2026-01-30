import EnsembleCore
import SwiftUI

struct WatchRootView: View {
    @StateObject private var authViewModel = DependencyContainer.shared.makeAuthViewModel()
    @StateObject private var nowPlayingVM = DependencyContainer.shared.makeNowPlayingViewModel()

    var body: some View {
        Group {
            switch authViewModel.authState {
            case .unknown:
                ProgressView()

            case .unauthenticated, .authenticating, .selectingServer, .selectingLibrary:
                WatchLoginView(viewModel: authViewModel)

            case .authenticated:
                WatchMainView(nowPlayingVM: nowPlayingVM)
            }
        }
        .task {
            await authViewModel.checkAuthState()
        }
    }
}

// MARK: - Watch Login View

struct WatchLoginView: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill")
                .font(.largeTitle)
                .foregroundColor(.accentColor)

            Text("Ensemble")
                .font(.headline)

            switch viewModel.authState {
            case .authenticating(let code, _):
                VStack(spacing: 8) {
                    Text("Enter code at")
                        .font(.caption2)
                    Text("plex.tv/link")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text(code)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

            case .selectingServer:
                VStack(spacing: 8) {
                    Text("Select Server")
                        .font(.caption)
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        ScrollView {
                            ForEach(viewModel.servers) { server in
                                Button(server.name) {
                                    Task {
                                        await viewModel.selectServer(server)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

            case .selectingLibrary:
                VStack(spacing: 8) {
                    Text("Select Library")
                        .font(.caption)
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        ScrollView {
                            ForEach(viewModel.libraries) { library in
                                Button(library.title) {
                                    Task {
                                        await viewModel.selectLibrary(library)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

            default:
                Button("Sign In") {
                    Task {
                        await viewModel.startAuth()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Watch Main View

struct WatchMainView: View {
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @StateObject private var libraryVM = DependencyContainer.shared.makeLibraryViewModel()

    var body: some View {
        TabView {
            // Now Playing
            WatchNowPlayingView(viewModel: nowPlayingVM)

            // Library
            WatchLibraryView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        }
        .tabViewStyle(.carousel)
        .task {
            await libraryVM.refresh()
        }
    }
}

// MARK: - Watch Now Playing

struct WatchNowPlayingView: View {
    @ObservedObject var viewModel: NowPlayingViewModel

    var body: some View {
        if let track = viewModel.currentTrack {
            VStack(spacing: 8) {
                // Track info
                VStack(spacing: 4) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if let artist = track.artistName {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // Progress
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)

                // Controls
                HStack(spacing: 20) {
                    Button(action: viewModel.previous) {
                        Image(systemName: "backward.fill")
                    }

                    Button(action: viewModel.togglePlayPause) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }

                    Button(action: viewModel.next) {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)

                // Time
                HStack {
                    Text(viewModel.formattedCurrentTime)
                    Spacer()
                    Text(viewModel.formattedRemainingTime)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .padding(.horizontal)
            }
            .padding()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)

                Text("Not Playing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Watch Library

struct WatchLibraryView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Recent") {
                    ForEach(libraryVM.tracks.prefix(10)) { track in
                        Button {
                            nowPlayingVM.play(track: track)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.caption)
                                    .lineLimit(1)

                                if let artist = track.artistName {
                                    Text(artist)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}
