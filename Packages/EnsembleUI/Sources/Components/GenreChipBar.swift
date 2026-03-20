import SwiftUI

// MARK: - Genre Chip Bar

/// Horizontal scrollable chip bar for quick genre filtering.
/// Only renders when there are 2+ available genres.
/// Uses OR logic: selecting multiple genres shows items matching any selected genre.
public struct GenreChipBar: View {
    let availableGenres: [String]
    @Binding var selectedGenres: Set<String>

    public init(availableGenres: [String], selectedGenres: Binding<Set<String>>) {
        // Filter out any empty/whitespace-only genre names
        self.availableGenres = availableGenres.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self._selectedGenres = selectedGenres
    }

    public var body: some View {
        if availableGenres.count >= 2 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Clear button (only when genres are selected)
                    if !selectedGenres.isEmpty {
                        Button {
                            selectedGenres.removeAll()
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
                            isSelected: selectedGenres.contains(genre),
                            onTap: {
                                if selectedGenres.contains(genre) {
                                    selectedGenres.remove(genre)
                                } else {
                                    selectedGenres.insert(genre)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 36)
        }
    }
}

// MARK: - Genre Chip

/// Individual chip within the GenreChipBar
private struct GenreChip: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(isSelected ? .white : .accentColor)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
    }
}
