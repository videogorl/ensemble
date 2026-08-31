import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Compact profile menu for toolbar placement.
/// Provides device-local library visibility controls and opens Settings.
public struct ProfileToolbarButton: View {
    @ObservedObject private var profileStore: UserProfileStore
    @ObservedObject private var accountManager: AccountManager
    @ObservedObject private var visibilityStore: LibraryVisibilityStore
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator

    public init(
        profileStore: UserProfileStore = DependencyContainer.shared.userProfileStore,
        accountManager: AccountManager = DependencyContainer.shared.accountManager,
        visibilityStore: LibraryVisibilityStore = DependencyContainer.shared.libraryVisibilityStore
    ) {
        self.profileStore = profileStore
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore
    }

    public var body: some View {
        let serverNames = accountManager.plexAccounts
            .flatMap(\.servers)
            .filter { $0.libraries.contains(where: \.isEnabled) }
            .map(\.name)
        // ponytail: Configured server lists are tiny; precompute counts if that changes.

        Menu {
            Section {
                Button("Settings", systemImage: EnsembleDesign.Icon.settings) {
                    navigationCoordinator.openProfile()
                }
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { settingsManager.mergingPreferences.isEnabled },
                        set: { enabled in
                            settingsManager.updateMergingPreferences { $0.isEnabled = enabled }
                        }
                    )
                ) {
                    Label("Merge Similar Items", systemImage: EnsembleDesign.Icon.merge)
                }
            }

            if visibilityStore.isFocusFilterActive {
                Section {
                    Toggle(
                        isOn: Binding(
                            get: { visibilityStore.isFocusFilterEnabled },
                            set: { visibilityStore.setFocusFilterEnabled($0) }
                        )
                    ) {
                        Label("Filtered by Focus", systemImage: EnsembleDesign.Icon.filterCircle)
                    }
                }
            }

            ForEach(accountManager.plexAccounts) { account in
                ForEach(account.servers) { server in
                    if server.libraries.contains(where: \.isEnabled) {
                        Section(
                            Self.serverSectionTitle(
                                server.name,
                                email: account.email,
                                isDuplicate: serverNames.filter { $0 == server.name }.count > 1
                            )
                        ) {
                            ForEach(server.libraries.filter(\.isEnabled)) { library in
                                sourceToggle(
                                    library.title,
                                    source: MusicSourceIdentifier(
                                        type: .plex,
                                        accountId: account.id,
                                        serverId: server.id,
                                        libraryId: library.key
                                    )
                                )
                            }
                        }
                    }
                }
            }

            #if os(iOS)
            if accountManager.isAppleMusicEnabled {
                sourceToggle("Apple Music", source: .appleMusic)
            }
            #endif

            Divider()

            Button("Show All") {
                visibilityStore.setHiddenSourceCompositeKeys(
                    visibilityStore.hiddenSourceCompositeKeys.subtracting(enabledSourceKeys)
                )
            }
            .disabled(
                visibilityStore.isFocusFilterEnabled ||
                    enabledSourceKeys.isDisjoint(with: visibilityStore.hiddenSourceCompositeKeys)
            )

            Button("Hide All") {
                visibilityStore.setHiddenSourceCompositeKeys(
                    visibilityStore.hiddenSourceCompositeKeys.union(enabledSourceKeys)
                )
            }
            .disabled(
                visibilityStore.isFocusFilterEnabled ||
                    enabledSourceKeys.isEmpty ||
                    enabledSourceKeys.isSubset(of: visibilityStore.hiddenSourceCompositeKeys)
            )
        } label: {
            #if os(macOS)
            macOSProfileImage
            #else
            profileImage
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(
            width: EnsembleScaffold.ProfileToolbar.imageDimension + EnsembleDesign.Spacing.md,
            height: EnsembleScaffold.ProfileToolbar.imageDimension
        )
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityIdentifier(AutomationIdentifiers.Sidebar.profileToolbar)
        .accessibilityLabel("Profile")
        .help("Profile Focus")
    }

    private var enabledSourceKeys: Set<String> {
        Set(accountManager.enabledSources().map(\.compositeKey))
    }

    private var effectiveHiddenSourceKeys: Set<String> {
        visibilityStore.effectiveHiddenSourceCompositeKeys(
            enabledSourceCompositeKeys: enabledSourceKeys
        )
    }

    static func serverSectionTitle(_ name: String, email: String?, isDuplicate: Bool) -> String {
        guard isDuplicate,
              let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            return name
        }
        return "\(name) (\(email))"
    }

    private func sourceToggle(_ title: String, source: MusicSourceIdentifier) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { !effectiveHiddenSourceKeys.contains(source.compositeKey) },
                set: {
                    visibilityStore.setSourceVisibility(
                        sourceCompositeKey: source.compositeKey,
                        isVisible: $0
                    )
                }
            )
        )
        .disabled(visibilityStore.isFocusFilterEnabled)
    }

    @ViewBuilder
    private var profileImage: some View {
        if let imageURL = profileStore.profileImageURL {
            LocalProfileImage(
                url: imageURL,
                reloadToken: profileStore.profile.lastModified
            ) {
                toolbarPlaceholder
            }
                .frame(
                    width: EnsembleScaffold.ProfileToolbar.imageDimension,
                    height: EnsembleScaffold.ProfileToolbar.imageDimension
                )
                .clipShape(Circle())
        } else {
            toolbarPlaceholder
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var macOSProfileImage: some View {
        if let imageURL = profileStore.profileImageURL,
           let image = Self.macOSToolbarProfileImage(at: imageURL) {
            Image(nsImage: image)
        } else {
            toolbarPlaceholder
        }
    }

    private static func macOSToolbarProfileImage(at url: URL) -> NSImage? {
        guard let source = NSImage(contentsOf: url) else { return nil }
        let dimension = EnsembleScaffold.ProfileToolbar.imageDimension
        let bounds = NSRect(x: 0, y: 0, width: dimension, height: dimension)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSBezierPath(ovalIn: bounds).addClip()
        source.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
    #endif

    private var toolbarPlaceholder: some View {
        Image(systemName: EnsembleDesign.Icon.profilePlaceholder)
            .font(EnsembleDesign.Typography.detailSubtitle)
    }
}
