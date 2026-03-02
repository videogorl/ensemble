import Combine
import Foundation

public struct OfflineServerLibraryToggle: Identifiable, Sendable {
    public let id: String
    public let sourceCompositeKey: String
    public let title: String
    public var isEnabled: Bool
}

public struct OfflineServerSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let libraries: [OfflineServerLibraryToggle]
}

@MainActor
public final class OfflineServersViewModel: ObservableObject {
    @Published public private(set) var sections: [OfflineServerSection] = []

    private let accountManager: AccountManager
    private let offlineDownloadService: OfflineDownloadService
    private var cancellables = Set<AnyCancellable>()

    public init(accountManager: AccountManager, offlineDownloadService: OfflineDownloadService) {
        self.accountManager = accountManager
        self.offlineDownloadService = offlineDownloadService

        accountManager.$plexAccounts
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        offlineDownloadService.$targets
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        rebuildSections()
    }

    public func refresh() async {
        await offlineDownloadService.refreshState()
        rebuildSections()
    }

    public func setLibraryEnabled(sourceCompositeKey: String, title: String, isEnabled: Bool) async {
        await offlineDownloadService.setLibraryDownloadEnabled(
            sourceCompositeKey: sourceCompositeKey,
            displayName: title,
            isEnabled: isEnabled
        )
        rebuildSections()
    }

    public func isLibraryEnabled(sourceCompositeKey: String) -> Bool {
        offlineDownloadService.isLibraryDownloadEnabled(sourceCompositeKey: sourceCompositeKey)
    }

    private func rebuildSections() {
        var updatedSections: [OfflineServerSection] = []

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                guard !enabledLibraries.isEmpty else { continue }

                let libraryToggles = enabledLibraries.map { library in
                    let sourceCompositeKey = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    ).compositeKey

                    return OfflineServerLibraryToggle(
                        id: sourceCompositeKey,
                        sourceCompositeKey: sourceCompositeKey,
                        title: library.title,
                        isEnabled: offlineDownloadService.isLibraryDownloadEnabled(sourceCompositeKey: sourceCompositeKey)
                    )
                }

                let section = OfflineServerSection(
                    id: "\(account.id):\(server.id)",
                    title: server.name,
                    subtitle: account.accountIdentifier,
                    libraries: libraryToggles.sorted {
                        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                )
                updatedSections.append(section)
            }
        }

        sections = updatedSections.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
