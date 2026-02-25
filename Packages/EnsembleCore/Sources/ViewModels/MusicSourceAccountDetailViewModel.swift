import Combine
import Foundation

/// Drives account-level source management, including library selection and sync status display.
@MainActor
public final class MusicSourceAccountDetailViewModel: ObservableObject {
    public struct ServerSection: Identifiable, Equatable {
        public let id: String
        public let serverName: String
        public let serverPlatform: String?
        public let libraries: [LibraryRow]

        public init(id: String, serverName: String, serverPlatform: String?, libraries: [LibraryRow]) {
            self.id = id
            self.serverName = serverName
            self.serverPlatform = serverPlatform
            self.libraries = libraries
        }
    }

    public struct LibraryRow: Identifiable, Equatable {
        public var id: String { sourceIdentifier.compositeKey }

        public let sourceIdentifier: MusicSourceIdentifier
        public let title: String
        public let isEnabled: Bool
        public let status: MusicSourceStatus?

        public init(
            sourceIdentifier: MusicSourceIdentifier,
            title: String,
            isEnabled: Bool,
            status: MusicSourceStatus?
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.title = title
            self.isEnabled = isEnabled
            self.status = status
        }
    }

    @Published public private(set) var accountIdentifier: String = ""
    @Published public private(set) var sections: [ServerSection] = []
    @Published public private(set) var isSyncingEnabledLibraries = false
    @Published public private(set) var isAccountMissing = false
    @Published public private(set) var error: String?

    private let accountId: String
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    private var cancellables = Set<AnyCancellable>()

    public var hasEnabledLibraries: Bool {
        sections.contains { section in
            section.libraries.contains(where: \.isEnabled)
        }
    }

    public init(
        accountId: String,
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator
    ) {
        self.accountId = accountId
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator

        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.sourceStatuses = statuses
                self?.rebuildSections()
            }
            .store(in: &cancellables)

        rebuildSections()
    }

    /// Toggles whether a single library is enabled for syncing under this account.
    public func toggleLibrary(_ row: LibraryRow) {
        error = nil

        let nextEnabledState = !row.isEnabled
        let didUpdate = accountManager.setLibraryEnabled(
            accountId: row.sourceIdentifier.accountId,
            serverId: row.sourceIdentifier.serverId,
            libraryKey: row.sourceIdentifier.libraryId,
            isEnabled: nextEnabledState
        )

        guard didUpdate else {
            error = "Could not update library selection."
            return
        }

        syncCoordinator.refreshProviders()
    }

    /// Triggers sync for all currently enabled libraries in this account.
    public func syncEnabledLibraries() async {
        guard !isSyncingEnabledLibraries else { return }

        let enabledSources = sections
            .flatMap(\.libraries)
            .filter(\.isEnabled)
            .map(\.sourceIdentifier)

        guard !enabledSources.isEmpty else {
            error = "Enable at least one library to sync."
            return
        }

        error = nil
        isSyncingEnabledLibraries = true
        defer { isSyncingEnabledLibraries = false }

        for source in enabledSources {
            await syncCoordinator.sync(source: source)
        }
    }

    private func rebuildSections() {
        guard let account = accountManager.plexAccounts.first(where: { $0.id == accountId }) else {
            isAccountMissing = true
            accountIdentifier = "Plex"
            sections = []
            return
        }

        isAccountMissing = false
        accountIdentifier = account.accountIdentifier

        sections = account.servers.map { server in
            let libraries = server.libraries.map { library in
                let sourceIdentifier = MusicSourceIdentifier(
                    type: .plex,
                    accountId: account.id,
                    serverId: server.id,
                    libraryId: library.key
                )

                let status = library.isEnabled ? (sourceStatuses[sourceIdentifier] ?? MusicSourceStatus()) : nil

                return LibraryRow(
                    sourceIdentifier: sourceIdentifier,
                    title: library.title,
                    isEnabled: library.isEnabled,
                    status: status
                )
            }

            return ServerSection(
                id: server.id,
                serverName: server.name,
                serverPlatform: server.platform,
                libraries: libraries
            )
        }
    }
}
