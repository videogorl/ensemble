import EnsembleCore
import SwiftUI

public struct GenresView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @State private var searchText = ""

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
            await libraryVM.refresh()
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

            Text("Tap the sync button to sync your library")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
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
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 140)
        }
    }
}