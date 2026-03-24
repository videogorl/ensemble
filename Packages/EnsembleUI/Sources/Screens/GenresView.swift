import EnsembleCore
import SwiftUI

public struct GenresView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @State private var searchText = ""
    @State private var showingManageSources = false
    @ObservedObject private var navigationCoordinator = DependencyContainer.shared.navigationCoordinator

    public init(libraryVM: LibraryViewModel) {
        self.libraryVM = libraryVM
    }
    
    private var filteredGenres: [Genre] {
        let sorted = libraryVM.sortedGenres
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { genre in
            genre.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        Group {
            if libraryVM.isLoading && libraryVM.genres.isEmpty {
                loadingView
            } else if libraryVM.genres.isEmpty {
                emptyView
            } else {
                genreListView
            }
        }
        .navigationTitle("Genres")
        #if os(iOS)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        #else
        .searchable(text: $searchText)
        #endif
        .refreshable {
            await libraryVM.refreshFromServer()
        }
        .sheet(isPresented: $showingManageSources) {
            NavigationView {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingManageSources = false
                            }
                        }
                    }
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading genres...")
                .foregroundColor(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "guitars")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Genres")
                .font(.title2)

            if !libraryVM.hasAnySources {
                Text("No music sources connected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    navigationCoordinator.showingAddAccount = true
                } label: {
                    Label("Add Source", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else if libraryVM.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Sync in progress…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if !libraryVM.hasEnabledLibraries {
                Text("No libraries enabled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingManageSources = true
                } label: {
                    Label("Manage Sources", systemImage: "slider.horizontal.3")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
            } else {
                Text("No genres found in enabled libraries")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var genreListView: some View {
        List {
            ForEach(filteredGenres) { genre in
                HStack {
                    Image(systemName: "guitars.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                        .frame(width: 44)

                    Text(genre.title)
                        .font(.body)

                    Spacer()
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerBottomSpacing(140)
    }
}
