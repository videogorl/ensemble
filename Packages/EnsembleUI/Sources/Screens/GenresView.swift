import EnsembleCore
import SwiftUI

public struct GenresView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let onGenreTap: (Genre) -> Void

    public init(libraryVM: LibraryViewModel, onGenreTap: @escaping (Genre) -> Void) {
        self.libraryVM = libraryVM
        self.onGenreTap = onGenreTap
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
            ForEach(libraryVM.genres) { genre in
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
