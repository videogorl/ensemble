import EnsembleCore
import SwiftUI

/// The "More" tab containing additional sections not in the main tab bar
public struct MoreView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    let onSyncTap: () -> Void
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    
    @State private var isEditing = false

    public init(
        libraryVM: LibraryViewModel,
        nowPlayingVM: NowPlayingViewModel,
        onSyncTap: @escaping () -> Void
    ) {
        self.libraryVM = libraryVM
        self.nowPlayingVM = nowPlayingVM
        self.onSyncTap = onSyncTap
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
                            Label(tab.rawValue, systemImage: tab.systemImage)
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
                                Label(tab.rawValue, systemImage: tab.systemImage)
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
                        NavigationLink {
                            destinationForTab(tab)
                        } label: {
                            Label(tab.rawValue, systemImage: tab.systemImage)
                        }
                    }
                }
                
                Section("Other") {
                    ForEach(moreTabs.filter { !isLibraryTab($0) }) { tab in
                        NavigationLink {
                            destinationForTab(tab)
                        } label: {
                            Label(tab.rawValue, systemImage: tab.systemImage)
                        }
                    }
                    
                    Button {
                        onSyncTap()
                    } label: {
                        Label("Library Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
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
    
    @ViewBuilder
    private func destinationForTab(_ tab: TabItem) -> some View {
        switch tab {
        case .home:
            HomeView(nowPlayingVM: nowPlayingVM, onAlbumTap: { _ in }, onArtistTap: { _ in })
        case .songs:
            SongsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        case .artists:
            ArtistsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, onArtistTap: { _ in })
        case .albums:
            AlbumsView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM, onAlbumTap: { _ in })
        case .genres:
            GenresView(libraryVM: libraryVM) { _ in }
        case .playlists:
            PlaylistsView(nowPlayingVM: nowPlayingVM) { _ in }
        case .favorites:
            FavoritesView(libraryVM: libraryVM, nowPlayingVM: nowPlayingVM)
        case .search:
            SearchView(nowPlayingVM: nowPlayingVM)
        case .downloads:
            DownloadsView(nowPlayingVM: nowPlayingVM)
        case .settings:
            SettingsView()
        }
    }
}
