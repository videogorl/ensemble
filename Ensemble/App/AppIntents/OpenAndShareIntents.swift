import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation

/// Opens a selected local media item without starting playback.
struct OpenEnsembleMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Media in Ensemble"
    static var description = IntentDescription("Opens a song, artist, album, or playlist in Ensemble without playing it.")
    static var openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    @available(iOS 27.0, macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$media) in Ensemble")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let destination = NavigationCoordinator.systemMediaDestination(
            fromSourceScopedIdentifier: media.id
        ) {
            _ = NavigationCoordinator.routeExternalSearchInActiveScene(to: destination)
        }
        return .result(dialog: IntentDialog("Opening \(media.title) in Ensemble."))
    }
}

/// Produces the same portable URL used by the in-app Share Ensemble Link action.
struct GetEnsembleLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Ensemble Link"
    static var description = IntentDescription("Creates a library-independent Ensemble link for selected media.")

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get an Ensemble link for \(\.$media)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        guard let url = media.permalink.url else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return .result(value: url, dialog: IntentDialog("Created an Ensemble link for \(media.title)."))
    }
}
