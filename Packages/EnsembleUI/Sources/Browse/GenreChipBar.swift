import SwiftUI

// MARK: - Genre Chip Bar

/// Standard header wrapper for browse/detail genre filters.
/// Keep screen-specific surfaces using this wrapper instead of positioning
/// `GenreChipBar` directly so spacing stays consistent across media types.
public struct GenreFilterHeader<Supplementary: View>: View {
    let availableGenres: [String]
    @Binding var selectedGenres: Set<String>
    @Binding var excludedGenres: Set<String>
    let supplementary: Supplementary

    public init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>,
        @ViewBuilder supplementary: () -> Supplementary
    ) {
        self.availableGenres = availableGenres
        self._selectedGenres = selectedGenres
        self._excludedGenres = excludedGenres
        self.supplementary = supplementary()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.sm) {
            supplementary
            GenreChipBar(
                availableGenres: availableGenres,
                selectedGenres: $selectedGenres,
                excludedGenres: $excludedGenres
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension GenreFilterHeader where Supplementary == EmptyView {
    init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>
    ) {
        self.init(
            availableGenres: availableGenres,
            selectedGenres: selectedGenres,
            excludedGenres: excludedGenres
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

    public init(
        availableGenres: [String],
        selectedGenres: Binding<Set<String>>,
        excludedGenres: Binding<Set<String>>
    ) {
        // Filter out any empty/whitespace-only genre names
        self.availableGenres = availableGenres.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self._selectedGenres = selectedGenres
        self._excludedGenres = excludedGenres
    }

    /// Whether any genre chips are active (included or excluded)
    private var hasActiveChips: Bool {
        !selectedGenres.isEmpty || !excludedGenres.isEmpty
    }

    public var body: some View {
        if !availableGenres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                if #available(iOS 26, macOS 26, *) {
                    GlassEffectContainer(spacing: EnsembleScaffold.Chip.rowSpacing) {
                        chipRow
                    }
                    .padding(.vertical, GenreChipBarLayout.materialBleed)
                } else {
                    chipRow
                        .padding(.vertical, GenreChipBarLayout.materialBleed)
                }
            }
            .genreChipScrollClipping()
            .frame(height: GenreChipBarLayout.barHeight)
        }
    }

    private var chipRow: some View {
        HStack(spacing: EnsembleScaffold.Chip.rowSpacing) {
            // Clear button — animates width to/from zero so it doesn't
            // cause a jarring shift when chips are toggled mid-scroll
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedGenres.removeAll()
                    excludedGenres.removeAll()
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
    static let materialBleed = EnsembleDesign.Spacing.chipVertical
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
/// Neutral: accent border + accent text.
/// Included: accent fill + white text.
/// Excluded: red border + red text + strikethrough.
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
                .genreChipMaterial(backgroundColor: backgroundColor, tintsGlass: state == .included)
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: state == .included ? 0 : EnsembleScaffold.Chip.borderWidth)
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
    func genreChipMaterial(backgroundColor: Color, tintsGlass: Bool) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if tintsGlass {
                self
                    .clipShape(Capsule())
                    .glassEffect(.regular.tint(backgroundColor).interactive(), in: .capsule)
            } else {
                self
                    .clipShape(Capsule())
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            self
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
        }
    }
}
