import EnsembleCore
import SwiftUI

/// Sheet view for reordering hub sections on the Home screen.
/// Shows hub categories with generic descriptions for dynamic hubs
/// (like Plexamp's approach), so users order *types* of content
/// rather than specific instances that will change.
public struct HubOrderingSheet: View {
    @ObservedObject var viewModel: HomeViewModel
    @State private var reorderedHubs: [Hub] = []

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        DesktopSheetScaffold(
            title: "Home Screen",
            subtitle: headerSubtitle
        ) {
            hubList
        } footer: {
            Button("Reset") {
                handleReset()
            }

            Button("Done") {
                viewModel.exitEditMode(save: true)
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            reorderedHubs = viewModel.editableHubs
        }
        .onChange(of: reorderedHubs) { newValue in
            viewModel.editableHubs = newValue
        }
        .onChange(of: viewModel.editableHubs) { newValue in
            reorderedHubs = newValue
        }
    }
    #endif

    private var iOSBody: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerBanner
                hubList
            }
            .navigationTitle("Home Screen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                toolbarContent
            }
        }
        .onAppear {
            reorderedHubs = viewModel.editableHubs
        }
        .onChange(of: reorderedHubs) { newValue in
            viewModel.editableHubs = newValue
        }
        .onChange(of: viewModel.editableHubs) { newValue in
            reorderedHubs = newValue
        }
    }

    private var headerSubtitle: String {
        if viewModel.currentSourceName.isEmpty {
            return "Drag to reorder sections"
        } else {
            return "Drag to reorder sections\n\(viewModel.currentSourceName)"
        }
    }

    private var headerBanner: some View {
        VStack(spacing: 4) {
            Text("Drag to reorder sections")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if !viewModel.currentSourceName.isEmpty {
                Text(viewModel.currentSourceName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(headerBackgroundColor)
    }

    private var headerBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return Color.secondary.opacity(0.1)
        #endif
    }

    private var hubList: some View {
        List {
            ForEach(reorderedHubs.indices, id: \.self) { index in
                let hub = reorderedHubs[index]
                let libraryName = viewModel.libraryName(forHubId: hub.id)
                let displayInfo = Self.displayInfo(for: hub, libraryName: libraryName)

                HStack(spacing: 12) {
                    // Drag handle (6-dot grid like Plexamp)
                    Image(systemName: "circle.grid.2x3.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        // Category name (generic for dynamic hubs)
                        Text(displayInfo.title)
                            .lineLimit(1)

                        // Subtitle showing current value for dynamic hubs
                        if let subtitle = displayInfo.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Library badge for artist hubs from specific libraries
                    if let badge = displayInfo.badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
                .padding(.vertical, 4)
            }
            .onMove(perform: moveHub)
        }
        .listStyle(.inset)
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Reset") {
                handleReset()
            }
            .foregroundColor(.red)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done") {
                viewModel.exitEditMode(save: true)
            }
            .font(.body.bold())
        }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button("Reset") {
                handleReset()
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                viewModel.exitEditMode(save: true)
            }
        }
        #endif
    }

    // MARK: - Actions

    private func moveHub(from source: IndexSet, to destination: Int) {
        reorderedHubs.move(fromOffsets: source, toOffset: destination)
    }

    private func handleReset() {
        viewModel.resetOrder()
    }

    // MARK: - Hub Display Mapping

    /// Display information for the ordering sheet.
    /// Dynamic hubs show a generic category name with the current value as subtitle.
    struct HubDisplayInfo {
        let title: String
        let subtitle: String?
        let badge: String?  // Library name badge for artist hubs
    }

    /// Maps a hub to its category display name, optional subtitle, and optional library badge.
    /// Dynamic hubs (which rotate their content) show a generic category title
    /// so the ordering screen stays stable across refreshes.
    static func displayInfo(for hub: Hub, libraryName: String? = nil) -> HubDisplayInfo {
        let hubIdentifier = extractHubIdentifier(from: hub.id)

        switch hubIdentifier {
        // Static hubs — show actual title
        case let id where id.hasPrefix("music.recent.played"):
            return HubDisplayInfo(title: "Recent Plays", subtitle: nil, badge: nil)
        case let id where id.hasPrefix("music.recent.added"):
            return HubDisplayInfo(title: "Recently Added", subtitle: nil, badge: nil)
        case let id where id.hasPrefix("music.popular"):
            return HubDisplayInfo(title: "Most Played", subtitle: currentValue(from: hub.title, prefix: "Most Played"), badge: nil)

        // Dynamic/contextual hubs — show generic category with current value as subtitle.
        // These stay separate per library, so show library badge to distinguish them.
        case let id where id.hasPrefix("music.recent.artist"):
            return HubDisplayInfo(title: "More by ... (artist)", subtitle: hub.title, badge: libraryName)
        case let id where id.hasPrefix("music.top.period"):
            return HubDisplayInfo(title: "Top Albums from ... (period)", subtitle: hub.title, badge: libraryName)
        case let id where id.hasPrefix("music.recent.genre"):
            return HubDisplayInfo(title: "More in ... (genre)", subtitle: hub.title, badge: libraryName)
        case let id where id.hasPrefix("music.recent.label"):
            return HubDisplayInfo(title: "More from ... (record label)", subtitle: hub.title, badge: libraryName)
        case let id where id.hasPrefix("music.vault"):
            return HubDisplayInfo(title: "Haven't played in ... (period)", subtitle: hub.title, badge: libraryName)

        // Other hubs — show as-is
        case let id where id.hasPrefix("music.touring"):
            return HubDisplayInfo(title: "Artists on Tour", subtitle: nil, badge: nil)
        case let id where id.hasPrefix("music.videos"):
            return HubDisplayInfo(title: "Music Videos", subtitle: nil, badge: nil)
        case let id where id.hasPrefix("home.playlists"):
            return HubDisplayInfo(title: "Recent Playlists", subtitle: nil, badge: nil)
        case let id where id.hasPrefix("home.music.recent"):
            return HubDisplayInfo(title: "Recently Added Music", subtitle: nil, badge: nil)

        default:
            return HubDisplayInfo(title: hub.title, subtitle: nil, badge: nil)
        }
    }

    /// Extract the hubIdentifier portion from a full hub ID.
    /// Hub IDs are "plex:{acct}:{srv}:{lib}:{hubIdentifier}" or "plex:{acct}:{srv}:merged:{typeId}:{title}"
    private static func extractHubIdentifier(from hubId: String) -> String {
        let components = hubId.split(separator: ":")

        // Merged hub: "plex:acct:srv:merged:music.recent.added:Recently Added"
        if components.count >= 5, components[3] == "merged" {
            return String(components[4])
        }

        // Normal hub: "plex:acct:srv:lib:music.recent.added.3"
        if components.count >= 5 {
            return components.dropFirst(4).joined(separator: ":")
        }

        return hubId
    }

    /// Extract a subtitle from a hub title given a known prefix
    /// e.g. "Most Played in March" with prefix "Most Played" -> "in March"
    private static func currentValue(from title: String, prefix: String) -> String? {
        guard title.count > prefix.count else { return nil }
        let remainder = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return remainder.isEmpty ? nil : remainder
    }
}
