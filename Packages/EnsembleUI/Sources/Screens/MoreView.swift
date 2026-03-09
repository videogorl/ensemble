import EnsembleCore
import SwiftUI

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
        List {
            if isEditing {
                Section {
                    Text("Select up to 4 items to appear in the main tab bar. Drag to reorder. Others will appear here in the More menu.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                
                Section("Tab Bar Items") {
                    ForEach(settingsManager.enabledTabs) { tab in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)
                            Label(tab.displayTitle, systemImage: tab.systemImage)
                            Spacer()
                            Button {
                                toggleTab(tab)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .onMove { indices, newOffset in
                        var current = settingsManager.enabledTabs
                        current.move(fromOffsets: indices, toOffset: newOffset)
                        settingsManager.enabledTabs = current
                    }
                }
                
                Section("Available Items") {
                    ForEach(TabItem.allCases.filter { $0 != .settings && !settingsManager.enabledTabs.contains($0) }) { tab in
                        Button {
                            toggleTab(tab)
                        } label: {
                            HStack {
                                Label(tab.displayTitle, systemImage: tab.systemImage)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .foregroundColor(.primary)
                        .disabled(settingsManager.enabledTabs.count >= 4)
                    }
                }
            } else {
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
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
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
    
    private func isLibraryTab(_ tab: TabItem) -> Bool {
        switch tab {
        case .home, .songs, .artists, .albums, .genres, .playlists, .favorites:
            return true
        default:
            return false
        }
    }
    
    private func toggleTab(_ tab: TabItem) {
        var current = settingsManager.enabledTabs
        if let index = current.firstIndex(of: tab) {
            // Don't allow removing if it's the only one? 
            // Actually, we need at least one tab.
            if current.count > 1 {
                current.remove(at: index)
            }
        } else {
            current.append(tab)
        }
        settingsManager.enabledTabs = current
    }
}
