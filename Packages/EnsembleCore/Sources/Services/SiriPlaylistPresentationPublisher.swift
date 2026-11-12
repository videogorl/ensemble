import EnsembleSiriShared
import EnsembleSupport
import Foundation

/// Keeps the App Group copy of the playlist presentation (merge setting, hidden playlist sources) current for the Siri
/// extension, which cannot read the app's settings. A completed catalog refresh publishes it with the index it was
/// computed for; a change to the setting, source visibility or source configuration republishes it for the current
/// index, and a change to hidden media rebuilds the catalog. An unchanged value is not rewritten.
@MainActor
public final class SiriPlaylistPresentationPublisher {
    private let settingsManager: SettingsManager
    private let visibilityStore: LibraryVisibilityStore
    private let accountManager: AccountManager
    private let indexStore: SiriMediaIndexStore
    private let hiddenMediaStore: HiddenMediaStore
    private var subscriptions: [StreamSubscription] = []
    private var lastPublished: SiriPlaylistPresentation?
    /// Called after a changed presentation is published, so Spotlight can follow it.
    var onChange: (@MainActor () async -> Void)?

    public init(
        settingsManager: SettingsManager,
        visibilityStore: LibraryVisibilityStore,
        accountManager: AccountManager,
        indexStore: SiriMediaIndexStore,
        hiddenMediaStore: HiddenMediaStore
    ) {
        self.settingsManager = settingsManager
        self.visibilityStore = visibilityStore
        self.accountManager = accountManager
        self.indexStore = indexStore
        self.hiddenMediaStore = hiddenMediaStore
        subscriptions.append(settingsManager.snapshots().map(\.mergingPreferences).removeDuplicates().dropFirst().observe(self) { publisher, _ in
            publisher.republish()
        })
        subscriptions.append(visibilityStore.snapshots().dropFirst().observe(self) { publisher, _ in publisher.republish() })
        subscriptions.append(accountManager.sourceConfigurations().dropFirst().observe(self) { publisher, _ in publisher.republish() })
        // Hiding one playlist changes what the catalog holds, so it takes a rebuild, which publishes.
        subscriptions.append(hiddenMediaStore.snapshots().dropFirst().observe(self) { publisher, _ in
            Task { await publisher.onChange?() }
        })
    }

    /// The merge setting and the playlist sources the playlist screen hides, among those `index` holds playlists for.
    func presentation(for index: SiriMediaIndex) -> SiriPlaylistPresentation {
        let sourceKeys = Set(index.items.filter { $0.kind == .playlist }.compactMap(\.sourceCompositeKey))
        let isVisible = visibilityStore.playlistSourceVisibility(in: accountManager.sourceConfigurationSnapshot)
        return SiriPlaylistPresentation(
            preferences: settingsManager.mergingPreferences,
            hiddenSourceKeys: sourceKeys.filter { !isVisible($0) },
            indexGeneratedAt: index.generatedAt
        )
    }

    /// Writes the presentation for `index`, the generation the extension will read.
    func publish(for index: SiriMediaIndex) async {
        let presentation = presentation(for: index)
        guard presentation != lastPublished else { return }
        do {
            try presentation.write()
            lastPublished = presentation
        } catch {
            EnsembleLogger.error("Siri playlist presentation could not be published: \(error)")
        }
    }

    private func republish() {
        Task {
            guard let index = await indexStore.loadIndexUnbounded() else { return }
            await publish(for: index)
            await onChange?()
        }
    }
}
