import EnsembleCore
import SwiftUI

public struct GenresView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let onGenreTap: (Genre) -> Void
    @State private var searchText = ""

    public init(libraryVM: LibraryViewModel, onGenreTap: @escaping (Genre) -> Void) {
        self.libraryVM = libraryVM
        self.onGenreTap = onGenreTap
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
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
                Button {
                    onGenreTap(genre)
                } label: {
                    HStack {
                        Image(systemName: "guitars.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 44)

                        Text(genre.title)
                            .font(.body)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }
}
