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
                        if index > 0 {
                            Divider().padding(.leading, 52)
                        }
                        tabEditRow(tab: tab)
                            .background(
                                // Highlight when this is the drop target position
                                dropTargetSection == .tabBar && dropTargetIndex == index
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear
                            )
                            .onDrag {
                                draggedTab = tab
                                return NSItemProvider(object: tab.rawValue as NSString)
                            }
                    }
                }
            }
            .sectionBackground()
            .padding(.horizontal, 16)
            .onDrop(of: [.text], delegate: TabBarDropDelegate(
                settingsManager: settingsManager,
                draggedTab: $draggedTab,
                dropTargetIndex: $dropTargetIndex,
                dropTargetSection: $dropTargetSection
            ))
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

    private func sectionHeaderText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    // MARK: - Actions

    /// Tap an available item to add it to the tab bar, bumping the last item if at capacity
    private func addTabToBar(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        if current.count >= 4 {
            // Bump the last item to available
            current.removeLast()
        }
        current.append(tab)
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

/// Handles drops into the tab bar section. Supports reordering within the section
/// and accepting items from the available section (bumping last if at 4 items).
private struct TabBarDropDelegate: DropDelegate {
    let settingsManager: SettingsManager
    @Binding var draggedTab: TabItem?
    @Binding var dropTargetIndex: Int?
    @Binding var dropTargetSection: EditTabDropSection?

    func dropEntered(info: DropInfo) {
        dropTargetSection = .tabBar
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
            let targetIndex = dropTargetIndex ?? current.count - 1
            current.remove(at: sourceIndex)
            let insertIndex = min(targetIndex, current.count)
            current.insert(draggedTab, at: insertIndex)
        } else {
            // Moving from available to tab bar
            if current.count >= 4 {
                // Bump last item
                current.removeLast()
            }
            let insertIndex = min(dropTargetIndex ?? current.count, current.count)
            current.insert(draggedTab, at: insertIndex)
        }

        settingsManager.enabledTabs = current
        cleanup()
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetSection == .tabBar {
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
