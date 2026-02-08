import EnsembleCore
import SwiftUI

/// Inline filter bar that slides up from bottom, similar to iOS control center
public struct InlineFilterBar: View {
    @Binding var filterOptions: FilterOptions
    @Binding var isExpanded: Bool

    public init(
        filterOptions: Binding<FilterOptions>,
        isExpanded: Binding<Bool>
    ) {
        self._filterOptions = filterOptions
        self._isExpanded = isExpanded
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            dragHandle

            if isExpanded {
                filterContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 16 : 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: -5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
    }

    private var dragHandle: some View {
        VStack(spacing: 8) {
            // Visual drag indicator
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            // Quick filter chips when collapsed
            if !isExpanded {
                quickFilterChips
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isExpanded.toggle()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -20 {
                        // Swipe up
                        withAnimation {
                            isExpanded = true
                        }
                    } else if value.translation.height > 20 {
                        // Swipe down
                        withAnimation {
                            isExpanded = false
                        }
                    }
                }
        )
    }

    private var quickFilterChips: some View {
        HStack(spacing: 12) {
            // Downloaded only chip
            FilterChip(
                icon: "arrow.down.circle.fill",
                label: "Downloaded",
                isActive: filterOptions.showDownloadedOnly
            ) {
                withAnimation {
                    filterOptions.showDownloadedOnly.toggle()
                }
            }

            // Active filters count
            if filterOptions.hasActiveFilters {
                FilterChip(
                    icon: "line.3.horizontal.decrease.circle.fill",
                    label: "\(activeFilterCount) filters",
                    isActive: true
                ) {
                    withAnimation {
                        isExpanded = true
                    }
                }
            }

            Spacer()

            // Expand button
            Image(systemName: "chevron.up")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private var filterContent: some View {
        VStack(spacing: 16) {
            // Downloaded Only Toggle
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Downloaded Only")
                Spacer()
                Toggle("", isOn: $filterOptions.showDownloadedOnly)
                    .labelsHidden()
            }
            .padding(.horizontal)

            // Sort Direction
            Divider()

            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundColor(.accentColor)
                Text("Sort Direction")
                Spacer()
                Picker("", selection: $filterOptions.sortDirection) {
                    ForEach(SortDirection.allCases, id: \.self) { direction in
                        Text(direction.label).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal)

            // Clear filters button
            if filterOptions.hasActiveFilters {
                Divider()

                Button(action: clearFilters) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear All Filters")
                    }
                    .font(.subheadline)
                    .foregroundColor(.red)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
    }

    private var activeFilterCount: Int {
        var count = 0
        if filterOptions.showDownloadedOnly { count += 1 }
        if !filterOptions.searchText.isEmpty { count += 1 }
        if !filterOptions.selectedGenres.isEmpty { count += 1 }
        if !filterOptions.selectedArtists.isEmpty { count += 1 }
        if filterOptions.yearRange != nil { count += 1 }
        return count
    }

    private func clearFilters() {
        withAnimation {
            filterOptions.clearFilters()
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
            )
            .foregroundColor(isActive ? .white : .primary)
        }
    }
}
