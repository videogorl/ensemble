import EnsembleCore
import SwiftUI

/// Filter sheet for advanced filtering options
public struct FilterSheet: View {
    @Binding var filterOptions: FilterOptions
    @Environment(\.dismiss) private var dismiss
    
    // Available options for filtering
    let availableArtists: [String]
    let availableGenres: [String]
    let showYearFilter: Bool
    let showArtistFilter: Bool
    let showGenreFilter: Bool
    
    @State private var minYear: String = ""
    @State private var maxYear: String = ""
    
    public init(
        filterOptions: Binding<FilterOptions>,
        availableArtists: [String] = [],
        availableGenres: [String] = [],
        showYearFilter: Bool = false,
        showArtistFilter: Bool = false,
        showGenreFilter: Bool = false
    ) {
        self._filterOptions = filterOptions
        self.availableArtists = availableArtists.sorted()
        self.availableGenres = availableGenres.sorted()
        self.showYearFilter = showYearFilter
        self.showArtistFilter = showArtistFilter
        self.showGenreFilter = showGenreFilter
    }
    
    public var body: some View {
        NavigationView {
            Form {
                // Downloaded Only Section
                Section {
                    Toggle("Downloaded Only", isOn: $filterOptions.showDownloadedOnly)
                } header: {
                    Text("Availability")
                }
                
                // Year Range Section (for albums)
                if showYearFilter {
                    Section {
                        if filterOptions.yearRange != nil {
                            HStack {
                                Text("Year Range")
                                Spacer()
                                Text("\(filterOptions.yearRange!.lowerBound) - \(filterOptions.yearRange!.upperBound)")
                                    .foregroundColor(.secondary)
                            }
                            
                            Button("Clear Year Range") {
                                filterOptions.yearRange = nil
                                minYear = ""
                                maxYear = ""
                            }
                            .foregroundColor(.red)
                        } else {
                            HStack {
                                TextField("Min Year", text: $minYear)
                                    .keyboardType(.numberPad)
                                    .frame(maxWidth: .infinity)
                                
                                Text("to")
                                    .foregroundColor(.secondary)
                                
                                TextField("Max Year", text: $maxYear)
                                    .keyboardType(.numberPad)
                                    .frame(maxWidth: .infinity)
                            }
                            
                            Button("Apply Year Range") {
                                applyYearRange()
                            }
                            .disabled(minYear.isEmpty || maxYear.isEmpty)
                        }
                    } header: {
                        Text("Year")
                    }
                }
                
                // Artist Filter Section
                if showArtistFilter && !availableArtists.isEmpty {
                    Section {
                        if filterOptions.selectedArtists.isEmpty {
                            NavigationLink {
                                ArtistSelectionView(
                                    selectedArtists: $filterOptions.selectedArtists,
                                    availableArtists: availableArtists
                                )
                            } label: {
                                Text("Select Artists")
                            }
                        } else {
                            HStack {
                                Text("Selected Artists")
                                Spacer()
                                Text("\(filterOptions.selectedArtists.count)")
                                    .foregroundColor(.secondary)
                            }
                            
                            NavigationLink {
                                ArtistSelectionView(
                                    selectedArtists: $filterOptions.selectedArtists,
                                    availableArtists: availableArtists
                                )
                            } label: {
                                Text("Edit Selection")
                            }
                            
                            Button("Clear Artists") {
                                filterOptions.selectedArtists.removeAll()
                            }
                            .foregroundColor(.red)
                        }
                    } header: {
                        Text("Artists")
                    }
                }
                
                // Genre Filter Section
                if showGenreFilter && !availableGenres.isEmpty {
                    Section {
                        if filterOptions.selectedGenres.isEmpty {
                            NavigationLink {
                                GenreSelectionView(
                                    selectedGenres: $filterOptions.selectedGenres,
                                    availableGenres: availableGenres
                                )
                            } label: {
                                Text("Select Genres")
                            }
                        } else {
                            HStack {
                                Text("Selected Genres")
                                Spacer()
                                Text("\(filterOptions.selectedGenres.count)")
                                    .foregroundColor(.secondary)
                            }
                            
                            NavigationLink {
                                GenreSelectionView(
                                    selectedGenres: $filterOptions.selectedGenres,
                                    availableGenres: availableGenres
                                )
                            } label: {
                                Text("Edit Selection")
                            }
                            
                            Button("Clear Genres") {
                                filterOptions.selectedGenres.removeAll()
                            }
                            .foregroundColor(.red)
                        }
                    } header: {
                        Text("Genres")
                    }
                }
                
                // Clear All Section
                if filterOptions.hasActiveFilters {
                    Section {
                        Button("Clear All Filters") {
                            filterOptions.clearFilters()
                            minYear = ""
                            maxYear = ""
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Initialize year range fields if already set
            if let yearRange = filterOptions.yearRange {
                minYear = String(yearRange.lowerBound)
                maxYear = String(yearRange.upperBound)
            }
        }
    }
    
    private func applyYearRange() {
        guard let min = Int(minYear),
              let max = Int(maxYear),
              min <= max else {
            return
        }
        filterOptions.yearRange = min...max
    }
}

// MARK: - Artist Selection View

struct ArtistSelectionView: View {
    @Binding var selectedArtists: Set<String>
    let availableArtists: [String]
    
    var body: some View {
        List(availableArtists, id: \.self) { artist in
            Button {
                if selectedArtists.contains(artist) {
                    selectedArtists.remove(artist)
                } else {
                    selectedArtists.insert(artist)
                }
            } label: {
                HStack {
                    Text(artist)
                        .foregroundColor(.primary)
                    Spacer()
                    if selectedArtists.contains(artist) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Select Artists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Genre Selection View

struct GenreSelectionView: View {
    @Binding var selectedGenres: Set<String>
    let availableGenres: [String]
    
    var body: some View {
        List(availableGenres, id: \.self) { genre in
            Button {
                if selectedGenres.contains(genre) {
                    selectedGenres.remove(genre)
                } else {
                    selectedGenres.insert(genre)
                }
            } label: {
                HStack {
                    Text(genre)
                        .foregroundColor(.primary)
                    Spacer()
                    if selectedGenres.contains(genre) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Select Genres")
        .navigationBarTitleDisplayMode(.inline)
    }
}
