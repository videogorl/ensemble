import EnsembleCore
import SwiftUI

/// Home screen displaying dynamic content hubs from Plex servers
/// Hubs include Recently Added, Recently Played, Most Played, etc.
public struct HomeView: View {
    @StateObject private var viewModel: HomeViewModel
    @ObservedObject var nowPlayingVM: NowPlayingViewModel
    @State private var showingAddSourceFlow = false
    @Environment(\.dependencies) private var deps
    
    public init(nowPlayingVM: NowPlayingViewModel) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeHomeViewModel())
        self.nowPlayingVM = nowPlayingVM
    }
    
    public var body: some View {
        Group {
            if viewModel.isLoading && viewModel.hubs.isEmpty {
                loadingView
            } else if viewModel.hubs.isEmpty {
                emptyView
            } else {
                hubsScrollView
            }
        }
        .navigationTitle("Feed")
        .toolbar {
            ToolbarItem(placement: .primaryActionIfAvailable) {
                Button("Edit") {
                    viewModel.enterEditMode()
                    viewModel.isEditingOrder = true
                }
                .disabled(!viewModel.hasEnabledLibraries || viewModel.hubs.isEmpty)
                .opacity(viewModel.hasEnabledLibraries && !viewModel.hubs.isEmpty ? 1 : 0)
            }
        }
        .sheet(isPresented: $viewModel.isEditingOrder) {
            HubOrderingSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingAddSourceFlow) {
            AddPlexAccountView()
            #if os(macOS)
                .frame(width: 720, height: 560)
            #endif
        }
        .task {
            await viewModel.loadHubs()
        }
        .onAppear {
            viewModel.handleViewVisibilityChange(isVisible: true)
        }
        .onDisappear {
            viewModel.handleViewVisibilityChange(isVisible: false)
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
    }
    
    private var emptyView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer()
                    .frame(height: 60)
                
                Image(systemName: "house")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)
                
                Text("Welcome Home")
                    .font(.title2)
                
                VStack(spacing: 8) {
                    if let errorMessage = viewModel.error {
                        Text("Unable to load content")
                            .font(.subheadline)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if !viewModel.hasConfiguredAccounts {
                        Text("No music sources connected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text("Add a Plex account in Settings > Music Sources to populate Feed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button {
                            showingAddSourceFlow = true
                        } label: {
                            Label("Add Source", systemImage: "plus.circle.fill")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(20)
                        }
                        .buttonStyle(.plain)
                    } else if !viewModel.hasEnabledLibraries {
                        Text("No libraries enabled")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Text("Enable at least one library in Settings > Music Sources to populate Feed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Text("No content available yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Your Plex server may not have hub data available, or content may still be loading. Pull down to refresh.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .opacity(viewModel.hasEnabledLibraries ? 1 : 0.6)
                .disabled(!viewModel.hasEnabledLibraries)
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
    
    private var hubsScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(viewModel.hubs) { hub in
                    HubSection(hub: hub, nowPlayingVM: nowPlayingVM)
                }
            }
            .padding(.vertical)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    viewModel.handleScrollInteraction(isInteracting: true)
                }
                .onEnded { _ in
                    viewModel.handleScrollInteraction(isInteracting: false)
                }
        )
        .miniPlayerBottomSpacing(140)
    }
}

// MARK: - Hub Section

/// Displays a single hub section with horizontally scrolling content
struct HubSection: View {
    let hub: Hub
    let nowPlayingVM: NowPlayingViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text(hub.title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)
            
            // Horizontal scroll of items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(hub.items) { item in
                        HubItemCard(item: item, nowPlayingVM: nowPlayingVM)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Hub Item Card

/// Card view for individual hub items (albums, artists, tracks, playlists)
/// Uses local-first artwork loading and skeleton models for offline-friendly navigation
struct HubItemCard: View {
    let item: HubItem
    let nowPlayingVM: NowPlayingViewModel
    @Environment(\.dependencies) private var deps
    
    private var isArtist: Bool {
        item.type == "artist"
    }
    
    var body: some View {
        Group {
            if item.type == "track" {
                Button(action: handleTrackTap) {
                    cardContent
                }
            } else if #available(iOS 16.0, macOS 13.0, *) {
                NavigationLink(value: destination) {
                    cardContent
                }
            } else {
                // iOS 15 fallback
                NavigationLink {
                    destinationView
                } label: {
                    cardContent
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private var cardContent: some View {
        VStack(alignment: isArtist ? .center : .leading, spacing: 8) {
            // Artwork with circular corners for artists, rounded for others
            ArtworkView(
                path: item.thumbPath,
                sourceKey: item.sourceCompositeKey,
                ratingKey: item.id,
                size: .small,
                cornerRadius: isArtist ? 70 : 8
            )
            .frame(width: 140, height: 140)
            .clipped()
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
            
            // Text content
            VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(isArtist ? .center : .leading)
                
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(isArtist ? .center : .leading)
                }
                
                if item.type == "album", let year = item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 140, alignment: isArtist ? .center : .leading)
        }
    }
    
    private var destination: NavigationCoordinator.Destination? {
        switch item.type {
        case "album": return .album(id: item.id)
        case "artist": return .artist(id: item.id)
        case "playlist": return .playlist(id: item.id, sourceKey: item.sourceCompositeKey)
        default: return nil
        }
    }
    
    @ViewBuilder
    private var destinationView: some View {
        switch item.type {
        case "album":
            AlbumDetailLoader(albumId: item.id, nowPlayingVM: nowPlayingVM)
        case "artist":
            ArtistDetailLoader(artistId: item.id, nowPlayingVM: nowPlayingVM)
        case "playlist":
            PlaylistDetailLoader(
                playlistId: item.id,
                playlistSourceKey: item.sourceCompositeKey,
                nowPlayingVM: nowPlayingVM
            )
        default:
            EmptyView()
        }
    }
    
    private func handleTrackTap() {
        let track = item.track ?? Track(
            id: item.id,
            key: item.id,
            title: item.title,
            artistName: item.subtitle,
            thumbPath: item.thumbPath,
            sourceCompositeKey: item.sourceCompositeKey
        )
        nowPlayingVM.play(tracks: [track])
    }
}
