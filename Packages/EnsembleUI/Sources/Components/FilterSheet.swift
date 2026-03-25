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
    #if os(macOS)
    @State private var showingArtistSelection = false
    @State private var showingGenreSelection = false
    #endif

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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Filters")
                        .font(.title2)
                        .fontWeight(.semibold)

                    macOSToggleSection(
                        title: "Availability",
                        footer: nil
                    ) {
                        Toggle("Downloaded Only", isOn: $filterOptions.showDownloadedOnly)
                    }

                    if showHideSingles {
                        macOSToggleSection(
                            title: "Albums",
                            footer: "Hide albums with only one track"
                        ) {
                            Toggle("Hide Singles", isOn: $filterOptions.hideSingles)
                        }
                    }

                    if showYearFilter {
                        macOSToggleSection(
                            title: "Year",
                            footer: nil
                        ) {
                            if let yearRange = filterOptions.yearRange {
                                HStack {
                                    Text("Current Range")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(yearRange.lowerBound) - \(yearRange.upperBound)")
                                }

                                Button("Clear Year Range") {
                                    filterOptions.yearRange = nil
                                    minYear = ""
                                    maxYear = ""
                                }
                                .foregroundColor(.red)
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Min Year")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Min Year", text: $minYear)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Max Year")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Max Year", text: $maxYear)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                Button("Apply Year Range") {
                                    applyYearRange()
                                }
                                .disabled(minYear.isEmpty || maxYear.isEmpty)
                            }
                        }
                    }

                    if showArtistFilter && !availableArtists.isEmpty {
                        macOSToggleSection(
                            title: "Artists",
                            footer: nil
                        ) {
                            if filterOptions.selectedArtists.isEmpty {
                                Text("No artist filters applied")
                                    .foregroundColor(.secondary)
                            } else {
                                HStack {
                                    Text("Selected")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(filterOptions.selectedArtists.count)")
                                }
                            }

                            HStack(spacing: 12) {
                                Button(filterOptions.selectedArtists.isEmpty ? "Select Artists…" : "Edit Selection…") {
                                    showingArtistSelection = true
                                }

                                if !filterOptions.selectedArtists.isEmpty {
                                    Button("Clear") {
                                        filterOptions.selectedArtists.removeAll()
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                        }
                    }

                    if showGenreFilter && !availableGenres.isEmpty {
                        macOSToggleSection(
                            title: "Genres",
                            footer: nil
                        ) {
                            if filterOptions.selectedGenres.isEmpty {
                                Text("No genre filters applied")
                                    .foregroundColor(.secondary)
                            } else {
                                HStack {
                                    Text("Selected")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(filterOptions.selectedGenres.count)")
                                }
                            }

                            HStack(spacing: 12) {
                                Button(filterOptions.selectedGenres.isEmpty ? "Select Genres…" : "Edit Selection…") {
                                    showingGenreSelection = true
                                }

                                if !filterOptions.selectedGenres.isEmpty {
                                    Button("Clear") {
                                        filterOptions.selectedGenres.removeAll()
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                        }
                    }

                    if filterOptions.hasActiveFilters {
                        Button("Clear All Filters") {
                            filterOptions.clearFilters()
                            minYear = ""
                            maxYear = ""
                        }
                        .foregroundColor(.red)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .top)
            }

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
        .sheet(isPresented: $showingArtistSelection) {
            macOSSelectionSheet(title: "Artists") {
                ArtistSelectionView(
                    selectedArtists: $filterOptions.selectedArtists,
                    availableArtists: availableArtists
                )
            }
        }
        .sheet(isPresented: $showingGenreSelection) {
            macOSSelectionSheet(title: "Genres") {
                GenreSelectionView(
                    selectedGenres: $filterOptions.selectedGenres,
                    availableGenres: availableGenres
                )
            }
        }
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

    #if os(macOS)
    @ViewBuilder
    private func macOSToggleSection<Content: View>(
        title: String,
        footer: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content()

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func macOSSelectionSheet<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            content()

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    if title == "Artists" {
                        showingArtistSelection = false
                    } else {
                        showingGenreSelection = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 520)
    }
    #endif
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
