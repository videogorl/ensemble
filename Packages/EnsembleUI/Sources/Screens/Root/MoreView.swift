import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    @State private var isEditing = false

    public init() {}

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
            Section {
                ForEach(moreTabs.filter { isLibraryTab($0) }) { tab in
                    navigationCoordinator.routeLink(to: .view(tab), in: .settings) {
                        moreTabRowLabel(for: tab)
                    }
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                }

                navigationCoordinator.routeLink(to: .hidden, in: .settings) {
                    Label("Hidden", systemImage: "eye.slash")
                }
                .foregroundColor(EnsembleDesign.Color.primaryText)
            } header: {
                EnsembleUtilitySectionHeader("Library")
            }

            Section {
                ForEach(moreTabs.filter { !isLibraryTab($0) }) { tab in
                    navigationCoordinator.routeLink(to: .view(tab), in: .settings) {
                        moreTabRowLabel(for: tab)
                    }
                    .foregroundColor(EnsembleDesign.Color.primaryText)
                }
            } header: {
                EnsembleUtilitySectionHeader("Other")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .restoringRootSceneScrollPosition(.more)
    }

    private func moreTabRowLabel(for tab: TabItem) -> some View {
        HStack {
            Label(tab.displayTitle, systemImage: tab.designSystemImage)
            #if os(iOS)
            if #unavailable(iOS 16.0) {
                Spacer()
                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            #elseif os(macOS)
            if #unavailable(macOS 13.0) {
                Spacer()
                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .font(EnsembleDesign.Typography.rowSecondary)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            #endif
        }
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

// MARK: - Edit Tabs View

/// Native tab editor with reorder support for visible tab-bar items and
/// tap-to-add/remove actions for the remaining destinations.
private struct EditTabsView: View {
    @ObservedObject var settingsManager: SettingsManager

    // Available tabs exclude settings (always in tab bar area as a fixed item)
    private var availableTabs: [TabItem] {
        TabItem.allCases.filter { $0 != .settings && !settingsManager.enabledTabs.contains($0) }
    }

    var body: some View {
        List {
            Section {
                ForEach(settingsManager.enabledTabs, id: \.tabEditorEnabledID) { tab in
                    Button {
                        removeTabFromBar(tab)
                    } label: {
                        tabEditRow(tab: tab, accessory: .remove)
                    }
                    .buttonStyle(.plain)
                    .disabled(settingsManager.enabledTabs.count <= 1)
                }
                .onMove(perform: moveTabBarItems)
            } header: {
                EnsembleUtilitySectionHeader("Tab Bar Items")
            } footer: {
                Text("Drag visible tabs to reorder them.")
            }

            Section {
                if availableTabs.isEmpty {
                    Text("All items are in the tab bar")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                } else {
                    ForEach(availableTabs, id: \.tabEditorAvailableID) { tab in
                        Button {
                            addTabToBar(tab)
                        } label: {
                            tabEditRow(tab: tab, accessory: .add)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                EnsembleUtilitySectionHeader("Available Items")
            } footer: {
                Text("Tap an item to add it. The tab bar keeps the first four items visible.")
            }
        }
        .tabEditorActiveEditMode()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Row View

    private enum TabAccessory {
        case add
        case remove

        var systemImage: String {
            switch self {
            case .add: return EnsembleDesign.Icon.add
            case .remove: return EnsembleDesign.Icon.removeCircle
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .add: return "Add"
            case .remove: return "Remove"
            }
        }
    }

    private func tabEditRow(tab: TabItem, accessory: TabAccessory) -> some View {
        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
            Image(systemName: tab.designSystemImage)
                .foregroundColor(EnsembleDesign.Color.accent)
                .frame(width: EnsembleScaffold.TabEditor.rowIconWidth, alignment: .center)

            Text(tab.displayTitle)
                .font(EnsembleDesign.Typography.rowPrimary)

            Spacer(minLength: EnsembleDesign.Spacing.md)

            Image(systemName: accessory.systemImage)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
                .accessibilityLabel(accessory.accessibilityLabel)
        }
    }

    // MARK: - Actions

    private func moveTabBarItems(from source: IndexSet, to destination: Int) {
        var current = settingsManager.enabledTabs
        current.move(fromOffsets: source, toOffset: destination)
        settingsManager.enabledTabs = current
    }

    /// Tap an available item to add it to the tab bar. Inserts at end, items beyond
    /// 4 overflow back to available (the 4th item gets pushed out, not removed randomly).
    private func addTabToBar(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        current.append(tab)

        // Preserve the first three anchors and replace the fourth visible slot
        // with the newly selected tab when the bar is already full.
        if current.count > EnsembleScaffold.TabEditor.maximumTabBarItems {
            current.remove(at: EnsembleScaffold.TabEditor.maximumTabBarItems - 1)
        }

        withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.addRemoveAnimationDuration)) {
            settingsManager.enabledTabs = current
        }
    }

    private func removeTabFromBar(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        guard current.count > 1,
              let index = current.firstIndex(of: tab) else {
            return
        }
        current.remove(at: index)
        withAnimation(.easeInOut(duration: EnsembleScaffold.TabEditor.addRemoveAnimationDuration)) {
            settingsManager.enabledTabs = current
        }
    }
}

private extension TabItem {
    var tabEditorEnabledID: String { "enabled-\(rawValue)" }
    var tabEditorAvailableID: String { "available-\(rawValue)" }
}

private extension View {
    @ViewBuilder
    func tabEditorActiveEditMode() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}
