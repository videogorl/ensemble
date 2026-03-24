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
    let showHideSingles: Bool

    @State private var minYear: String = ""
    @State private var maxYear: String = ""

    public init(
        filterOptions: Binding<FilterOptions>,
        availableArtists: [String] = [],
        availableGenres: [String] = [],
        showYearFilter: Bool = false,
        showArtistFilter: Bool = false,
        showGenreFilter: Bool = false,
        showHideSingles: Bool = false
    ) {
        self._filterOptions = filterOptions
        self.availableArtists = availableArtists.sorted()
        self.availableGenres = availableGenres.sorted()
        self.showYearFilter = showYearFilter
        self.showArtistFilter = showArtistFilter
        self.showGenreFilter = showGenreFilter
        self.showHideSingles = showHideSingles
    }
    
    public var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            filterForm

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear(perform: initializeYearRange)
    }
    #endif

    private var iOSBody: some View {
        NavigationView {
            filterForm
            .navigationTitle("Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                #endif
            }
        }
        .onAppear(perform: initializeYearRange)
    }

    private var filterForm: some View {
        Form {
            // Downloaded Only Section
            Section {
                Toggle("Downloaded Only", isOn: $filterOptions.showDownloadedOnly)
            } header: {
                Text("Availability")
            }

            // Hide Singles Section (for albums)
            if showHideSingles {
                Section {
                    Toggle("Hide Singles", isOn: $filterOptions.hideSingles)
                } header: {
                    Text("Albums")
                } footer: {
                    Text("Hide albums with only one track")
                }
            }

            // Year Range Section (for albums)
            if showYearFilter {
                Section {
                    if let yearRange = filterOptions.yearRange {
                        HStack {
                            Text("Year Range")
                            Spacer()
                            Text("\(yearRange.lowerBound) - \(yearRange.upperBound)")
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
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                                .frame(maxWidth: .infinity)
                            
                            Text("to")
                                .foregroundColor(.secondary)
                            
                            TextField("Max Year", text: $maxYear)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
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
    }

    private func initializeYearRange() {
        // Initialize year range fields if already set
        if let yearRange = filterOptions.yearRange {
            minYear = String(yearRange.lowerBound)
            maxYear = String(yearRange.upperBound)
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
