import EnsembleSiriShared
import EnsembleSupport
import Foundation

/// Keeps the App Group copy of the playlist presentation (merge setting, hidden playlist sources) current for the Siri
/// extension, which cannot read the app's settings. Republishes when the setting, source visibility, source
/// configuration or catalog changes; an unchanged value is not rewritten.
@MainActor
public final class SiriPlaylistPresentationPublisher {
    private let settingsManager: SettingsManager
    private let visibilityStore: LibraryVisibilityStore
    private let accountManager: AccountManager
    private let indexStore: SiriMediaIndexStore
    private var subscriptions: [StreamSubscription] = []
    private var lastPublished: SiriPlaylistPresentation?
    /// Called after a changed presentation is published, so Spotlight can follow it.
    var onChange: (@MainActor () async -> Void)?

    public init(
        settingsManager: SettingsManager,
        visibilityStore: LibraryVisibilityStore,
        accountManager: AccountManager,
        indexStore: SiriMediaIndexStore,
        libraryChanges: LibraryChanges?
    ) {
        self.settingsManager = settingsManager
        self.visibilityStore = visibilityStore
        self.accountManager = accountManager
        self.indexStore = indexStore
        subscriptions.append(settingsManager.snapshots().map(\.mergingPreferences).removeDuplicates().observe(self) { publisher, _ in
            publisher.publish()
        })
        subscriptions.append(visibilityStore.snapshots().observe(self) { publisher, _ in publisher.publish() })
        subscriptions.append(accountManager.sourceConfigurations().observe(self) { publisher, _ in publisher.publish() })
        if let libraryChanges {
            subscriptions.append(libraryChanges.events([.catalogChanged]).observe(self) { publisher, _ in publisher.publish() })
        }
    }

    /// The merge setting and hidden playlist sources now. Hidden is decided per source the index holds playlists for.
    func currentPresentation() async -> SiriPlaylistPresentation {
        let sourceKeys = Set((await indexStore.loadIndexUnbounded()?.items ?? [])
            .filter { $0.kind == .playlist }.compactMap(\.sourceCompositeKey))
        let isVisible = visibilityStore.playlistSourceVisibility(in: accountManager.sourceConfigurationSnapshot)
        return SiriPlaylistPresentation(
            preferences: settingsManager.mergingPreferences,
            hiddenSourceKeys: sourceKeys.filter { !isVisible($0) }
        )
    }

    private func publish() {
        Task {
            let presentation = await currentPresentation()
            guard presentation != lastPublished else { return }
            do {
                try presentation.write()
                lastPublished = presentation
            } catch {
                EnsembleLogger.error("Siri playlist presentation could not be published: \(error)")
                return
            }
            await onChange?()
        }
    }
}
