import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct AddPlexAccountView: View {
    @StateObject private var viewModel: AddPlexAccountViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps

    public init() {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAddPlexAccountViewModel())
    }

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // App icon
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.house.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.accentColor)

                        Text("Add Plex Account")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }

                    // Auth content
                    authContent

                    // Error message
                    if let error = viewModel.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
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
        .frame(minWidth: 720, minHeight: 560)
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
            serverLibrarySelectionView

        case .selectingLibraries:
            serverLibrarySelectionView

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

            Button {
                copyToClipboard(code)
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Code copied",
                        message: "Paste it at plex.tv/link",
                        dedupeKey: "add-account-pin-copied"
                    )
                )
            } label: {
                VStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Tap to copy")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
                .frame(maxWidth: 320)
            }
            .buttonStyle(.plain)

            Link(destination: linkURL) {
                HStack {
                    Text("Open plex.tv/link")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.headline)
                .lineLimit(1)
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

    private var serverLibrarySelectionView: some View {
        VStack(spacing: 16) {
            Text("Select Servers and Libraries")
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
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.servers) { server in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)

                                Text(server.name)
                                    .font(.headline)

                                if let platform = server.platform {
                                    Text("(\(platform))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if let serverError = viewModel.serverLibraryErrors[server.id] {
                                Text(serverError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(.bottom, 4)
                            } else {
                                let serverLibraries = viewModel.libraries(for: server.id)
                                if serverLibraries.isEmpty {
                                    Text("No music libraries found")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ServerLibrariesSelection(
                                        libraries: serverLibraries
                                    ) { library in
                                        viewModel.isLibrarySelected(serverId: server.id, libraryKey: library.key)
                                    } onToggle: { library in
                                        viewModel.toggleLibrary(for: server.id, library: library)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

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
                .disabled(viewModel.selectedLibraryCompositeKeys.isEmpty)
            }
        }
    }

    private func copyToClipboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
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
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ServerLibrariesSelection: View {
    let libraries: [Library]
    let isSelected: (Library) -> Bool
    let onToggle: (Library) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(libraries) { library in
                LibrarySelectionRow(
                    library: library,
                    isSelected: isSelected(library)
                ) {
                    onToggle(library)
                }
            }
        }
    }
}
