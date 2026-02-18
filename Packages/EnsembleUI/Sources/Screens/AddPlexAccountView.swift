import EnsembleCore
import SwiftUI

public struct AddPlexAccountView: View {
    @StateObject private var viewModel: AddPlexAccountViewModel
    @Environment(\.dismiss) private var dismiss

    public init() {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAddPlexAccountViewModel())
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                Spacer()

                // App icon
                VStack(spacing: 16) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)

                    Text("Add Plex Account")
                        .font(.title2)
                        .fontWeight(.semibold)
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                #endif
            }
            .onChange(of: viewModel.state) { newState in
                if newState == .complete {
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 680)
        #endif
    }

    @ViewBuilder
    private var authContent: some View {
        switch viewModel.state {
        case .ready:
            signInButton

        case .authenticating(let code, let linkURL):
            pinView(code: code, linkURL: linkURL)

        case .selectingServer:
            serverSelectionView

        case .selectingLibraries:
            librarySelectionView

        case .complete:
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
        }
    }

    private var librarySelectionView: some View {
        VStack(spacing: 16) {
            Text("Select Libraries")
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
                            LibrarySelectionRow(
                                library: library,
                                isSelected: viewModel.selectedLibraryKeys.contains(library.key)
                            ) {
                                viewModel.toggleLibrary(library)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 300)

                Button {
                    viewModel.confirmLibraries()
                } label: {
                    Text("Add Account")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .disabled(viewModel.selectedLibraryKeys.isEmpty)
            }
        }
    }
}

// MARK: - Library Selection Row

struct LibrarySelectionRow: View {
    let library: Library
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .accentColor : .gray)
                    .frame(width: 44)

                Text(library.title)
                    .font(.headline)

                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
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
                    
                    if let platform = server.platform {
                        Text(platform)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}
