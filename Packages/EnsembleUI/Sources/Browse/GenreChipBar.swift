import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

// MARK: - Genre Chip Bar

/// Standard header wrapper for browse/detail genre filters.
/// Keep screen-specific surfaces using this wrapper instead of positioning
/// `GenreChipBar` directly so spacing stays consistent across media types.
public struct GenreFilterHeader<Supplementary: View>: View {
    let availableGenres: [String]
    @Binding var selectedGenres: Set<String>
    @Binding var excludedGenres: Set<String>
    @Binding var favoriteFilter: FavoriteFilter?
    let reservesEmptySpace: Bool
    let supplementary: Supplementary

    public init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>,
        favoriteFilter: Binding<FavoriteFilter?>,
        reservesEmptySpace: Bool = false,
        @ViewBuilder supplementary: () -> Supplementary
    ) {
        self.availableGenres = availableGenres
        self._selectedGenres = selectedGenres
        self._excludedGenres = excludedGenres
        self._favoriteFilter = favoriteFilter
        self.reservesEmptySpace = reservesEmptySpace
        self.supplementary = supplementary()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.sm) {
            supplementary
            GenreChipBar(
                availableGenres: availableGenres,
                selectedGenres: $selectedGenres,
                excludedGenres: $excludedGenres,
                favoriteFilter: $favoriteFilter,
                reservesEmptySpace: reservesEmptySpace
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension GenreFilterHeader where Supplementary == EmptyView {
    init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>,
        favoriteFilter: Binding<FavoriteFilter?>,
        reservesEmptySpace: Bool = false
    ) {
        self.init(
            availableGenres: availableGenres,
            selectedGenres: selectedGenres,
            excludedGenres: excludedGenres,
            favoriteFilter: favoriteFilter,
            reservesEmptySpace: reservesEmptySpace
        ) {
            EmptyView()
        }
    }
}

/// Horizontal scrollable chip bar for quick genre filtering.
/// Renders whenever there is at least one available genre.
/// Three-state toggle: tap to include → tap to exclude → tap to clear.
/// Include uses OR logic (any selected genre matches).
/// Exclude hides items matching any excluded genre.
public struct GenreChipBar: View {
    let availableGenres: [String]
    @Binding var selectedGenres: Set<String>
    @Binding var excludedGenres: Set<String>
    @Binding var favoriteFilter: FavoriteFilter?
    let reservesEmptySpace: Bool

    public init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>,
        favoriteFilter: Binding<FavoriteFilter?>,
        reservesEmptySpace: Bool = false
    ) {
        // Filter out any empty/whitespace-only genre names
        self.availableGenres = availableGenres.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self._selectedGenres = selectedGenres
        self._excludedGenres = excludedGenres
        self._favoriteFilter = favoriteFilter
        self.reservesEmptySpace = reservesEmptySpace
    }

    static let reservedHeight = GenreChipBarLayout.barHeight

    /// Whether any genre chips are active (included or excluded)
    private var hasActiveChips: Bool {
        favoriteFilter != nil || !selectedGenres.isEmpty || !excludedGenres.isEmpty
    }

    public var body: some View {
        if !availableGenres.isEmpty || favoriteFilter != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                if #available(iOS 26, macOS 26, *) {
                    GlassEffectContainer(spacing: EnsembleScaffold.Chip.rowSpacing) {
                        chipRow
                            .padding(.vertical, GenreChipBarLayout.materialBleed)
                    }
                } else {
                    chipRow
                        .padding(.vertical, GenreChipBarLayout.materialBleed)
                }
            }
            .genreChipScrollClipping()
            .frame(height: GenreChipBarLayout.barHeight)
        } else if reservesEmptySpace {
            Color.clear
                .frame(height: GenreChipBarLayout.barHeight)
        }
    }

    private var chipRow: some View {
        HStack(spacing: EnsembleScaffold.Chip.rowSpacing) {
            favoriteButton

            // Clear button — animates width to/from zero so it doesn't
            // cause a jarring shift when chips are toggled mid-scroll
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedGenres.removeAll()
                    excludedGenres.removeAll()
                    favoriteFilter = nil
                }
            } label: {
                Image(systemName: EnsembleDesign.Icon.closeCircle)
                    .font(.system(size: EnsembleScaffold.Chip.clearButtonIconSize, weight: .medium))
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            .buttonStyle(.plain)
            .frame(width: hasActiveChips ? nil : 0)
            .clipped()
            .opacity(hasActiveChips ? 1 : 0)
            .disabled(!hasActiveChips)
            .animation(.easeInOut(duration: 0.2), value: hasActiveChips)

            ForEach(availableGenres, id: \.self) { genre in
                GenreChip(
                    title: genre,
                    state: chipState(for: genre),
                    onTap: { cycleState(for: genre) }
                )
            }
        }
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
    }

    private var favoriteButton: some View {
        Button(action: cycleFavoriteFilter) {
            Image(systemName: favoriteIcon)
                .font(EnsembleDesign.Typography.chipLabel)
                .foregroundColor(favoriteFilter == nil ? EnsembleDesign.Color.secondaryText : EnsembleDesign.Color.accent)
                .padding(.horizontal, EnsembleScaffold.Chip.horizontalPadding)
                .padding(.vertical, EnsembleScaffold.Chip.verticalPadding)
                .genreChipMaterial(
                    backgroundColor: EnsembleDesign.Color.windowSurface,
                    borderColor: EnsembleDesign.Color.accent,
                    borderWidth: EnsembleScaffold.Chip.borderWidth,
                    tintsGlass: false
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Favorite Filter")
        .accessibilityValue(favoriteAccessibilityValue)
    }

    private var favoriteIcon: String {
        switch favoriteFilter {
        case nil: return EnsembleDesign.Icon.favorite
        case .favorites: return EnsembleDesign.Icon.favoriteFilled
        case .unfavorited: return EnsembleDesign.Icon.favoriteRemove
        }
    }

    private var favoriteAccessibilityValue: String {
        switch favoriteFilter {
        case nil: return "All Items"
        case .favorites: return "Favorites Only"
        case .unfavorited: return "Unfavorited Only"
        }
    }

    private func cycleFavoriteFilter() {
        switch favoriteFilter {
        case nil: favoriteFilter = .favorites
        case .favorites: favoriteFilter = .unfavorited
        case .unfavorited: favoriteFilter = nil
        }
    }

    /// Determine the current state of a genre chip
    private func chipState(for genre: String) -> GenreChipState {
        if selectedGenres.contains(genre) { return .included }
        if excludedGenres.contains(genre) { return .excluded }
        return .neutral
    }

    /// Cycle through states: neutral → included → excluded → neutral
    private func cycleState(for genre: String) {
        switch chipState(for: genre) {
        case .neutral:
            selectedGenres.insert(genre)
        case .included:
            selectedGenres.remove(genre)
            excludedGenres.insert(genre)
        case .excluded:
            excludedGenres.remove(genre)
        }
    }
}

private enum GenreChipBarLayout {
    static let materialBleed = EnsembleDesign.Spacing.lg
    static let barHeight = EnsembleScaffold.Chip.barHeight + (materialBleed * 2)
}

// MARK: - Genre Chip State

private enum GenreChipState {
    case neutral   // No filter applied
    case included  // Show only items with this genre
    case excluded  // Hide items with this genre
}

// MARK: - Genre Chip

/// Individual chip within the GenreChipBar.
/// Neutral: accent glass/text.
/// Included: accent-tinted glass + white text.
/// Excluded: neutral glass + red text + strikethrough.
private struct GenreChip: View {
    let title: String
    let state: GenreChipState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(EnsembleDesign.Typography.chipLabel)
                .strikethrough(state == .excluded)
                .lineLimit(1)
                .padding(.horizontal, EnsembleScaffold.Chip.horizontalPadding)
                .padding(.vertical, EnsembleScaffold.Chip.verticalPadding)
                .foregroundColor(foregroundColor)
                .genreChipMaterial(
                    backgroundColor: backgroundColor,
                    borderColor: borderColor,
                    borderWidth: state == .included ? 0 : EnsembleScaffold.Chip.borderWidth,
                    tintsGlass: state == .included
                )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch state {
        case .neutral: return EnsembleDesign.Color.accent
        case .included: return EnsembleDesign.Color.onAccent
        case .excluded: return EnsembleDesign.Color.destructive
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .neutral: return EnsembleDesign.Color.windowSurface
        case .included: return EnsembleDesign.Color.accent
        case .excluded: return EnsembleDesign.Color.windowSurface
        }
    }

    private var borderColor: Color {
        switch state {
        case .neutral: return EnsembleDesign.Color.accent
        case .included: return .clear
        case .excluded: return EnsembleDesign.Color.destructive
        }
    }
}

private extension View {
    @ViewBuilder
    func genreChipScrollClipping() -> some View {
        if #available(iOS 17, macOS 14, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }

    @ViewBuilder
    func genreChipMaterial(
        backgroundColor: Color,
        borderColor: Color,
        borderWidth: CGFloat,
        tintsGlass: Bool
    ) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if tintsGlass {
                self
                    .glassEffect(.regular.tint(backgroundColor).interactive(), in: .capsule)
            } else {
                self
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            self
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
        }
    }
}
