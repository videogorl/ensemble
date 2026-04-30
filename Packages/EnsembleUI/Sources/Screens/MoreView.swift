import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    let nowPlayingVM: NowPlayingViewModel
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @Environment(\.dependencies) private var deps
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    @State private var isEditing = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
    }

    private var barTabs: [TabItem] {
        Array(settingsManager.enabledTabs.prefix(EnsembleScaffold.TabEditor.maximumTabBarItems))
    }

    private var moreTabs: [TabItem] {
        // Exclude .settings — now accessed via profile toolbar button
        TabItem.allCases.filter { $0 != .settings && !barTabs.contains($0) }
    }

    public var body: some View {
        Group {
            if isEditing {
                editTabsView
            } else {
                browseView
            }
        }
        .miniPlayerBottomSpacing()
        .navigationTitle(isEditing ? "Edit Tabs" : "More")
        .profileToolbar()
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
            EnsembleToolbarLeadingSpacer()
            ToolbarItem(placement: .primaryActionIfAvailable) {
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
                            navigationCoordinator.push(.view(tab), in: .settings)
                        } label: {
                            HStack {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                                Spacer()
                                Image(systemName: EnsembleDesign.Icon.chevronRight)
                                    .font(EnsembleDesign.Typography.rowSecondary)
                                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                            }
                        }
                        .foregroundColor(EnsembleDesign.Color.primaryText)
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
                            navigationCoordinator.push(.view(tab), in: .settings)
                        } label: {
                            HStack {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                                Spacer()
                                Image(systemName: EnsembleDesign.Icon.chevronRight)
                                    .font(EnsembleDesign.Typography.rowSecondary)
                                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                            }
                        }
                        .foregroundColor(EnsembleDesign.Color.primaryText)
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
    // Row midpoints for computing drop index from Y position
    @State private var tabBarRowFrames: [Int: CGRect] = [:]

    // Available tabs exclude settings (always in tab bar area as a fixed item)
    private var availableTabs: [TabItem] {
        TabItem.allCases.filter { $0 != .settings && !settingsManager.enabledTabs.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Instructions
                Text("Drag items between sections to customize your tab bar. Tap available items to add them.")
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, EnsembleScaffold.TabEditor.instructionHorizontalPadding)
                    .padding(.top, EnsembleScaffold.TabEditor.instructionTopPadding)
                    .padding(.bottom, EnsembleScaffold.TabEditor.instructionBottomPadding)

                // Tab Bar Items section
                tabBarSection

                // Available Items section
                availableSection
            }
        }
        .onPreferenceChange(TabRowFramePreferenceKey.self) { frames in
            tabBarRowFrames = frames
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
                            Divider().padding(.leading, EnsembleScaffold.TabEditor.dividerLeadingPadding)
                        }
                        tabEditRow(tab: tab)
                            .background(
                                // Capture row frame relative to the drop target VStack
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TabRowFramePreferenceKey.self,
                                        value: [index: geo.frame(in: .named("tabBarDropTarget"))]
                                    )
                                }
                            )
                            .onDrag {
                                draggedTab = tab
                                return NSItemProvider(object: tab.rawValue as NSString)
                            }
                    }
                }

                // Insertion indicator at end
                if dropTargetSection == .tabBar && dropTargetIndex == settingsManager.enabledTabs.count {
                    insertionIndicator
                }
            }
            .coordinateSpace(name: "tabBarDropTarget")
            .sectionBackground()
            .padding(.horizontal, TrackListLayoutMetrics.utilitySectionOuterPadding)
            .onDrop(of: [.text], delegate: TabBarSectionDropDelegate(
                settingsManager: settingsManager,
                draggedTab: $draggedTab,
                dropTargetIndex: $dropTargetIndex,
                dropTargetSection: $dropTargetSection,
                rowFrames: tabBarRowFrames
            ))
        }
    }

    // MARK: - Available Section

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeaderText("AVAILABLE ITEMS")

            if availableTabs.isEmpty {
                Text("All items are in the tab bar")
                    .font(EnsembleDesign.Typography.stateMessage)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, EnsembleScaffold.TabEditor.emptyVerticalPadding)
                    .sectionBackground()
                    .padding(.horizontal, TrackListLayoutMetrics.utilitySectionOuterPadding)
                    .onDrop(of: [.text], delegate: AvailableDropDelegate(
                        settingsManager: settingsManager,
                        draggedTab: $draggedTab,
                        dropTargetIndex: $dropTargetIndex,
                        dropTargetSection: $dropTargetSection
                    ))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(availableTabs.enumerated()), id: \.element) { index, tab in
                        VStack(spacing: 0) {
                            if index > 0 {
                                Divider().padding(.leading, EnsembleScaffold.TabEditor.dividerLeadingPadding)
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
                .padding(.horizontal, TrackListLayoutMetrics.utilitySectionOuterPadding)
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
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Image(systemName: EnsembleDesign.Icon.dragReorder)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .font(EnsembleDesign.Typography.rowPrimary)

            Image(systemName: tab.systemImage)
                .foregroundColor(EnsembleDesign.Color.accent)
                .frame(width: EnsembleScaffold.TabEditor.rowIconWidth, alignment: .center)

            Text(tab.displayTitle)
                .font(EnsembleDesign.Typography.rowPrimary)

            Spacer()
        }
        .padding(.horizontal, TrackListLayoutMetrics.utilitySectionOuterPadding)
        .padding(.vertical, EnsembleScaffold.TabEditor.rowVerticalPadding)
    }

    /// Visual indicator showing where a dragged item will be inserted
    private var insertionIndicator: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(EnsembleDesign.Color.accent)
                .frame(
                    width: EnsembleScaffold.TabEditor.insertionDotSize,
                    height: EnsembleScaffold.TabEditor.insertionDotSize
                )
            Rectangle()
                .fill(EnsembleDesign.Color.accent)
                .frame(height: EnsembleScaffold.TabEditor.insertionLineHeight)
        }
        .padding(.horizontal, TrackListLayoutMetrics.rowHorizontalPadding)
        .transition(.opacity)
    }

    private func sectionHeaderText(_ text: String) -> some View {
        Text(text)
            .font(EnsembleDesign.Typography.rowSecondary)
            .foregroundColor(EnsembleDesign.Color.secondaryText)
            .padding(.horizontal, TrackListLayoutMetrics.detailHorizontalPadding)
            .padding(.top, EnsembleScaffold.TabEditor.sectionHeaderTopPadding)
            .padding(.bottom, EnsembleScaffold.TabEditor.sectionHeaderBottomPadding)
    }

    // MARK: - Actions

    /// Tap an available item to add it to the tab bar. Inserts at end, items beyond
    /// 4 overflow back to available (the 4th item gets pushed out, not removed randomly).
    private func addTabToBar(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        current.append(tab)
        // Truncate to the visible tab-bar cap; overflow falls back to available.
        if current.count > EnsembleScaffold.TabEditor.maximumTabBarItems {
            current = Array(current.prefix(EnsembleScaffold.TabEditor.maximumTabBarItems))
        }
        withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.addRemoveAnimationDuration)) {
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
            .cornerRadius(EnsembleScaffold.TabEditor.sectionCornerRadius)
        #else
        self
            .background(Color(.controlBackgroundColor))
            .cornerRadius(EnsembleScaffold.TabEditor.sectionCornerRadius)
        #endif
    }
}

// MARK: - Tab Row Frame Preference Key

/// Captures per-row frames so the drop delegate can compute insertion index from Y position.
private struct TabRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Tab Bar Section Drop Delegate

/// Single drop delegate for the entire tab bar section. Computes the insertion index
/// from the drop Y position using captured row frames.
private struct TabBarSectionDropDelegate: DropDelegate {
    let settingsManager: SettingsManager
    @Binding var draggedTab: TabItem?
    @Binding var dropTargetIndex: Int?
    @Binding var dropTargetSection: EditTabDropSection?
    let rowFrames: [Int: CGRect]

    func dropEntered(info: DropInfo) {
        dropTargetSection = .tabBar
        updateIndex(from: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndex(from: info)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedTab else {
            cleanup()
            return false
        }

        let targetIndex = dropTargetIndex ?? settingsManager.enabledTabs.count
        var current = settingsManager.enabledTabs

        if let sourceIndex = current.firstIndex(of: draggedTab) {
            // Reorder within tab bar
            current.remove(at: sourceIndex)
            let adjustedIndex = sourceIndex < targetIndex ? max(targetIndex - 1, 0) : targetIndex
            let insertIndex = min(adjustedIndex, current.count)
            current.insert(draggedTab, at: insertIndex)
        } else {
            // Moving from available to tab bar — insert at position, overflow past 4
            let insertIndex = min(targetIndex, current.count)
            current.insert(draggedTab, at: insertIndex)
            if current.count > EnsembleScaffold.TabEditor.maximumTabBarItems {
                current = Array(current.prefix(EnsembleScaffold.TabEditor.maximumTabBarItems))
            }
        }

        withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.reorderAnimationDuration)) {
            settingsManager.enabledTabs = current
        }
        cleanup()
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTargetSection == .tabBar {
            withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.dropExitAnimationDuration)) {
                dropTargetIndex = nil
                dropTargetSection = nil
            }
        }
    }

    /// Compute insertion index from the drop's Y position relative to row midpoints
    private func updateIndex(from info: DropInfo) {
        let dropY = info.location.y
        let count = settingsManager.enabledTabs.count

        // Find which row the drop is above by checking midpoints
        var newIndex = count // Default: append at end
        for i in 0..<count {
            if let frame = rowFrames[i] {
                let midY = frame.midY
                if dropY < midY {
                    newIndex = i
                    break
                }
            }
        }

        if newIndex != dropTargetIndex {
            withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.dropExitAnimationDuration)) {
                dropTargetIndex = newIndex
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
            // Enforce minimum one tab.
            guard current.count > 1 else {
                cleanup()
                return false
            }
            current.remove(at: index)
            withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.reorderAnimationDuration)) {
                settingsManager.enabledTabs = current
            }
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
