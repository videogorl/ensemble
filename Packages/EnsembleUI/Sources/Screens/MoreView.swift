import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Environment(\.dependencies) private var deps

    @State private var isEditing = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(4))
    }

    private var moreTabs: [TabItem] {
        TabItem.allCases.filter { !barTabs.contains($0) }
    }

    public var body: some View {
        Group {
            if isEditing {
                editTabsView
            } else {
                browseView
            }
        }
        .miniPlayerBottomSpacing(140)
        .navigationTitle(isEditing ? "Edit Tabs" : "More")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation {
                        isEditing.toggle()
                    }
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation {
                        isEditing.toggle()
                    }
                }
            }
            #endif
        }
    }

    // MARK: - Browse Mode

    private var browseView: some View {
        List {
            Section("Library") {
                ForEach(moreTabs.filter { isLibraryTab($0) }) { tab in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.view(tab)) {
                            Label(tab.displayTitle, systemImage: tab.systemImage)
                        }
                    } else {
                        // iOS 15 Fallback: Use manual push to coordinator to sync with NavigationView
                        Button {
                            deps.navigationCoordinator.push(.view(tab), in: .settings)
                        } label: {
                            HStack {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }

            Section("Other") {
                ForEach(moreTabs.filter { !isLibraryTab($0) }) { tab in
                    if #available(iOS 16.0, macOS 13.0, *) {
                        NavigationLink(value: NavigationCoordinator.Destination.view(tab)) {
                            Label(tab.displayTitle, systemImage: tab.systemImage)
                        }
                    } else {
                        // iOS 15 Fallback
                        Button {
                            deps.navigationCoordinator.push(.view(tab), in: .settings)
                        } label: {
                            HStack {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Edit Tabs Mode

    private var editTabsView: some View {
        EditTabsView(settingsManager: settingsManager)
    }

    private func isLibraryTab(_ tab: TabItem) -> Bool {
        switch tab {
        case .home, .songs, .artists, .albums, .genres, .playlists, .favorites:
            return true
        default:
            return false
        }
    }
}

// MARK: - Edit Tab Drop Section

/// Which section a drop target is in
private enum EditTabDropSection {
    case tabBar
    case available
}

// MARK: - Edit Tabs View

/// Full drag-and-drop tab editor with two sections: Tab Bar Items and Available Items.
/// Supports drag between sections, reordering within the tab bar, and tap to add/remove.
private struct EditTabsView: View {
    @ObservedObject var settingsManager: SettingsManager

    // Drag-and-drop tracking
    @State private var draggedTab: TabItem?
    @State private var dropTargetIndex: Int?
    @State private var dropTargetSection: EditTabDropSection?

    // Available tabs exclude settings (always in tab bar area as a fixed item)
    private var availableTabs: [TabItem] {
        TabItem.allCases.filter { $0 != .settings && !settingsManager.enabledTabs.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Instructions
                Text("Drag items between sections to customize your tab bar. Tap available items to add them.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                // Tab Bar Items section
                tabBarSection

                // Available Items section
                availableSection
            }
        }
        #if os(iOS)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        #endif
    }

    // MARK: - Tab Bar Section

    private var tabBarSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeaderText("TAB BAR ITEMS")

            VStack(spacing: 0) {
                ForEach(Array(settingsManager.enabledTabs.enumerated()), id: \.element) { index, tab in
                    VStack(spacing: 0) {
                        // Insertion indicator before this row
                        if dropTargetSection == .tabBar && dropTargetIndex == index {
                            insertionIndicator
                        }

                        if index > 0 && !(dropTargetSection == .tabBar && dropTargetIndex == index) {
                            Divider().padding(.leading, 52)
                        }
                        tabEditRow(tab: tab)
                            .onDrag {
                                draggedTab = tab
                                return NSItemProvider(object: tab.rawValue as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabBarRowDropDelegate(
                                index: index,
                                settingsManager: settingsManager,
                                draggedTab: $draggedTab,
                                dropTargetIndex: $dropTargetIndex,
                                dropTargetSection: $dropTargetSection
                            ))
                    }
                }

                // Drop zone at end of list + insertion indicator
                if dropTargetSection == .tabBar && dropTargetIndex == settingsManager.enabledTabs.count {
                    insertionIndicator
                }

                // Invisible drop target for appending to end
                Color.clear
                    .frame(height: 20)
                    .onDrop(of: [.text], delegate: TabBarRowDropDelegate(
                        index: settingsManager.enabledTabs.count,
                        settingsManager: settingsManager,
                        draggedTab: $draggedTab,
                        dropTargetIndex: $dropTargetIndex,
                        dropTargetSection: $dropTargetSection
                    ))
            }
            .sectionBackground()
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Available Section

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeaderText("AVAILABLE ITEMS")

            if availableTabs.isEmpty {
                Text("All items are in the tab bar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                    .sectionBackground()
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(availableTabs.enumerated()), id: \.element) { index, tab in
                        VStack(spacing: 0) {
                            if index > 0 {
                                Divider().padding(.leading, 52)
                            }
                            tabEditRow(tab: tab)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    addTabToBar(tab)
                                }
                                .onDrag {
                                    draggedTab = tab
                                    return NSItemProvider(object: tab.rawValue as NSString)
                                }
                        }
                    }
                }
                .sectionBackground()
                .padding(.horizontal, 16)
                .onDrop(of: [.text], delegate: AvailableDropDelegate(
                    settingsManager: settingsManager,
                    draggedTab: $draggedTab,
                    dropTargetIndex: $dropTargetIndex,
                    dropTargetSection: $dropTargetSection
                ))
            }
        }
    }

    // MARK: - Row View

    private func tabEditRow(tab: TabItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.body)

            Image(systemName: tab.systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 24, alignment: .center)

            Text(tab.displayTitle)
                .font(.body)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Visual indicator showing where a dragged item will be inserted
    private var insertionIndicator: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.horizontal, 12)
        .transition(.opacity)
    }

    private func sectionHeaderText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Actions

    /// Tap an available item to add it to the tab bar. Inserts at end, items beyond
    /// 4 overflow back to available (the 4th item gets pushed out, not removed randomly).
    private func addTabToBar(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        current.append(tab)
        // Truncate to 4 — the 5th item (previously 4th) falls back to available
        if current.count > 4 {
            current = Array(current.prefix(4))
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            settingsManager.enabledTabs = current
        }
    }
}

// MARK: - Section Background Modifier

/// Provides a grouped-inset-list-style background for manual row sections
private extension View {
    func sectionBackground() -> some View {
        #if os(iOS)
        self
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
        #else
        self
            .background(Color(.controlBackgroundColor))
            .cornerRadius(10)
        #endif
    }
}

// MARK: - Tab Bar Drop Delegate

/// Per-row drop delegate for the tab bar section. Each row knows its index,
/// so hovering over a row sets the insertion indicator at that position.
private struct TabBarRowDropDelegate: DropDelegate {
    let index: Int
    let settingsManager: SettingsManager
    @Binding var draggedTab: TabItem?
    @Binding var dropTargetIndex: Int?
    @Binding var dropTargetSection: EditTabDropSection?

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetSection = .tabBar
            dropTargetIndex = index
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedTab else {
            cleanup()
            return false
        }

        var current = settingsManager.enabledTabs

        if let sourceIndex = current.firstIndex(of: draggedTab) {
            // Reorder within tab bar
            current.remove(at: sourceIndex)
            // Adjust index if the source was before the target
            let adjustedIndex = sourceIndex < index ? max(index - 1, 0) : index
            let insertIndex = min(adjustedIndex, current.count)
            current.insert(draggedTab, at: insertIndex)
        } else {
            // Moving from available to tab bar — insert at position, overflow past 4
            let insertIndex = min(index, current.count)
            current.insert(draggedTab, at: insertIndex)
            // Truncate to 4 — items pushed past position 3 fall back to available
            if current.count > 4 {
                current = Array(current.prefix(4))
            }
        }

        settingsManager.enabledTabs = current
        cleanup()
        return true
    }

    func dropExited(info: DropInfo) {
        // Only clear if we're still the active target
        if dropTargetSection == .tabBar && dropTargetIndex == index {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetIndex = nil
                dropTargetSection = nil
            }
        }
    }

    private func cleanup() {
        draggedTab = nil
        dropTargetIndex = nil
        dropTargetSection = nil
    }
}

// MARK: - Available Drop Delegate

/// Handles drops into the available section. Removes the item from the tab bar
/// (enforcing minimum 1 tab).
private struct AvailableDropDelegate: DropDelegate {
    let settingsManager: SettingsManager
    @Binding var draggedTab: TabItem?
    @Binding var dropTargetIndex: Int?
    @Binding var dropTargetSection: EditTabDropSection?

    func dropEntered(info: DropInfo) {
        dropTargetSection = .available
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedTab else {
            cleanup()
            return false
        }

        var current = settingsManager.enabledTabs

        // Only process if the tab is currently in the tab bar
        if let index = current.firstIndex(of: draggedTab) {
            // Enforce minimum 1 tab
            guard current.count > 1 else {
                cleanup()
                return false
            }
            current.remove(at: index)
            settingsManager.enabledTabs = current
        }

        cleanup()
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetSection == .available {
            dropTargetIndex = nil
            dropTargetSection = nil
        }
    }

    private func cleanup() {
        draggedTab = nil
        dropTargetIndex = nil
        dropTargetSection = nil
    }
}
