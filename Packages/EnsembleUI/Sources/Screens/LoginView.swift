import EnsembleCore
import SwiftUI

public struct LoginView: View {
    @ObservedObject var viewModel: AuthViewModel

    public init(viewModel: AuthViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                // App icon/logo
                VStack(spacing: 16) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.accentColor)

                    Text("Ensemble")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Music player for Plex")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Auth content
                authContent

                Spacer()

                // Error message
                if let error = viewModel.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding()
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var authContent: some View {
        switch viewModel.authState {
        case .unknown, .unauthenticated:
            signInButton

        case .authenticating(let code, let linkURL):
            pinView(code: code, linkURL: linkURL)

        case .selectingServer:
            serverSelectionView

        case .selectingLibrary:
            librarySelectionView

        case .authenticated:
            // This state means we're transitioning
            ProgressView()
        }
    }

    private var signInButton: some View {
        VStack(spacing: 16) {
            Button {
                Task {
                    await viewModel.startAuth()
                }
            } label: {
                HStack {
                    Image(systemName: "person.circle.fill")
                    Text("Sign in with Plex")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(viewModel.isLoading)

            if viewModel.isLoading {
                ProgressView()
            }
        }
        .padding(.horizontal, 32)
    }

    private func pinView(code: String, linkURL: URL) -> some View {
        VStack(spacing: 24) {
            Text("Enter this code at plex.tv/link")
                .font(.headline)

            // PIN code display
            Text(code)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .tracking(8)
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)

            Link(destination: linkURL) {
                HStack {
                    Text("Open plex.tv/link")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.headline)
            }

            Text("Waiting for authorization...")
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView()

            Button("Cancel") {
                viewModel.cancelAuth()
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var serverSelectionView: some View {
        VStack(spacing: 16) {
            Text("Select a Server")
                .font(.headline)

            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.servers.isEmpty {
                Text("No servers found")
                    .foregroundColor(.secondary)

                Button("Refresh") {
                    Task {
                        await viewModel.loadServers()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.servers) { server in
                            ServerRow(server: server) {
                                Task {
                                    await viewModel.selectServer(server)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 300)
            }

            Button("Sign Out") {
                Task {
                    await viewModel.signOut()
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var librarySelectionView: some View {
        VStack(spacing: 16) {
            Text("Select a Music Library")
                .font(.headline)

            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.libraries.isEmpty {
                Text("No music libraries found")
                    .foregroundColor(.secondary)

                Button("Refresh") {
                    Task {
                        await viewModel.loadLibraries()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.libraries) { library in
                            LibraryRow(library: library) {
                                Task {
                                    await viewModel.selectLibrary(library)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 300)
            }

            Button("Sign Out") {
                Task {
                    await viewModel.signOut()
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.headline)

                    HStack(spacing: 4) {
                        if server.isLocal {
                            Image(systemName: "wifi")
                                .font(.caption2)
                        }
                        Text(server.platform ?? "Server")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library Row

struct LibraryRow: View {
    let library: Library
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.house")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                    .frame(width: 44)

                Text(library.title)
                    .font(.headline)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}
