import AppIntents
import EnsembleCore
import Foundation
import OSLog

private enum EnsembleFocusFilterLogger {
    static let logger = Logger(
        subsystem: "com.videogorl.ensemble.focus-filter",
        category: "FocusFilter"
    )
}

enum EnsembleFocusScrobblingSetting: String, AppEnum {
    case useAppSetting
    case enabled
    case disabled

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scrobbling")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .useAppSetting: "Use Ensemble Setting",
        .enabled: "Enabled",
        .disabled: "Disabled"
    ]

    var overrideValue: Bool? {
        switch self {
        case .useAppSetting: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    var summary: String {
        switch self {
        case .useAppSetting: return "App scrobbling setting"
        case .enabled: return "Scrobbling on"
        case .disabled: return "Scrobbling off"
        }
    }
}

struct EnsembleLibraryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library")
    static var defaultQuery = EnsembleLibraryEntityQuery()

    let id: String
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

struct EnsembleLibraryEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [EnsembleLibraryEntity.ID]) async throws -> [EnsembleLibraryEntity] {
        let wanted = Set(identifiers)
        return Self.availableLibraries().filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [EnsembleLibraryEntity] {
        Self.availableLibraries()
    }

    @MainActor
    private static func availableLibraries() -> [EnsembleLibraryEntity] {
        let accountManager = AppRoot.container.accountManager
        if accountManager.credentialLoadState == .loading, accountManager.plexAccounts.isEmpty {
            accountManager.loadAccounts()
        }

        return accountManager.enabledSources().compactMap { source in
            guard let presentation = accountManager.sourcePresentation(for: source.compositeKey) else {
                return nil
            }
            if source.type == .appleMusic {
                return EnsembleLibraryEntity(
                    id: source.compositeKey,
                    title: presentation.capabilities.displayName,
                    subtitle: nil
                )
            }
            return EnsembleLibraryEntity(
                id: source.compositeKey,
                title: presentation.libraryName,
                subtitle: "\(presentation.serverName) • \(presentation.accountName)"
            )
        }
        .sorted {
            ($0.title, $0.subtitle ?? "", $0.id) < ($1.title, $1.subtitle ?? "", $1.id)
        }
    }
}

/// Applies temporary playback and library-visibility overrides for the active system Focus.
struct EnsembleFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Playback & Libraries"
    static var description = IntentDescription(
        "Choose which Ensemble libraries are visible and whether playback scrobbles while this Focus is active."
    )

    @Parameter(title: "Libraries to Show")
    var visibleLibraries: [EnsembleLibraryEntity]?

    @Parameter(title: "Scrobbling", default: .useAppSetting)
    var scrobbling: EnsembleFocusScrobblingSetting

    var displayRepresentation: DisplayRepresentation {
        let librarySummary: String
        switch visibleLibraries?.count {
        case nil:
            librarySummary = "App library visibility"
        case 1:
            librarySummary = visibleLibraries?.first?.title ?? "1 library"
        case let count?:
            librarySummary = "\(count) libraries"
        }
        return DisplayRepresentation(
            title: "Filter Ensemble",
            subtitle: "\(librarySummary), \(scrobbling.summary)"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        apply(resetsLibraryBypass: true)
        return .result()
    }

    @MainActor
    static func refreshCurrent() async {
        do {
            let currentFilter = try await Self.current
            currentFilter.apply(resetsLibraryBypass: false)
        } catch {
            clearOverrides()
            EnsembleFocusFilterLogger.logger.info(
                "FOCUS_FILTER: using app settings because no active configuration was found"
            )
        }
    }

    @MainActor
    private func apply(resetsLibraryBypass: Bool) {
        let visibleSourceKeys = visibleLibraries.map { Set($0.map(\.id)) }
        AppRoot.container.libraryVisibilityStore.setFocusVisibleSourceCompositeKeys(
            visibleSourceKeys,
            resetsBypass: resetsLibraryBypass
        )
        AppRoot.container.settingsManager.setFocusScrobblingOverride(
            scrobbling.overrideValue
        )
        EnsembleFocusFilterLogger.logger.info(
            "FOCUS_FILTER: applied libraries=\(visibleSourceKeys?.count ?? 0, privacy: .public) libraryOverride=\(visibleSourceKeys != nil, privacy: .public) scrobbling=\(scrobbling.rawValue, privacy: .public)"
        )
    }

    @MainActor
    private static func clearOverrides() {
        AppRoot.container.libraryVisibilityStore.setFocusVisibleSourceCompositeKeys(nil)
        AppRoot.container.settingsManager.setFocusScrobblingOverride(nil)
    }
}
