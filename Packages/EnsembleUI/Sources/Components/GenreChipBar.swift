import SwiftUI

// MARK: - Genre Chip Bar

/// Horizontal scrollable chip bar for quick genre filtering.
/// Only renders when there are 2+ available genres.
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
        if availableGenres.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Clear button (when any genres are included or excluded)
                    if hasActiveChips {
                        Button {
                            selectedGenres.removeAll()
                            excludedGenres.removeAll()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(availableGenres, id: \.self) { genre in
                        GenreChip(
                            title: genre,
                            state: chipState(for: genre),
                            onTap: { cycleState(for: genre) }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 36)
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
                .font(.subheadline)
                .strikethrough(state == .excluded)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(foregroundColor)
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: state == .included ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch state {
        case .neutral: return .accentColor
        case .included: return .white
        case .excluded: return .red
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .neutral: return .clear
        case .included: return .accentColor
        case .excluded: return .clear
        }
    }

    private var borderColor: Color {
        switch state {
        case .neutral: return .accentColor
        case .included: return .clear
        case .excluded: return .red
        }
    }
}
