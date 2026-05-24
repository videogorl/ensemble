import Foundation

public enum IPodDatabaseAdapterError: LocalizedError, Equatable {
    case unavailable
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iPod sync is unavailable."
        case .unsupported(let message):
            return message
        }
    }
}

public protocol IPodDatabaseAdapting: Sendable {
    func canAccessDatabase() async -> Bool
    func readLibrary(device: IPodDeviceSnapshot) async throws -> IPodLibrarySnapshot
    func commitAdditiveSync(device: IPodDeviceSnapshot) async throws -> ExternalDeviceSyncSummary
}

public struct ExternalIPodHelperLocator: Sendable {
    public let candidateURLs: [URL]
    private let isExecutableFile: @Sendable (URL) -> Bool

    public init(
        candidateURLs: [URL] = Self.defaultCandidateURLs(),
        isExecutableFile: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.isExecutableFile(atPath: url.path)
        }
    ) {
        self.candidateURLs = candidateURLs
        self.isExecutableFile = isExecutableFile
    }

    public func installedHelperURL() -> URL? {
        candidateURLs.first { isExecutableFile($0) }
    }

    public static func defaultCandidateURLs(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let appRelativePath = "Ensemble iPod Helper.app/Contents/MacOS/Ensemble iPod Helper"
        return [
            URL(fileURLWithPath: "/Applications").appendingPathComponent(appRelativePath),
            homeDirectory.appendingPathComponent("Applications").appendingPathComponent(appRelativePath)
        ]
    }
}

/// Boundary for a separately distributed classic iPod helper.
///
/// Classic iPods require database writes, not plain file copies. The Mac App Store
/// app keeps that native/libgpod dependency outside the bundle and exposes sync
/// only when the separate helper is already installed.
public struct ExternalIPodHelperAdapter: IPodDatabaseAdapting {
    private let locator: ExternalIPodHelperLocator

    public init(locator: ExternalIPodHelperLocator = ExternalIPodHelperLocator()) {
        self.locator = locator
    }

    public func canAccessDatabase() async -> Bool {
        locator.installedHelperURL() != nil
    }

    public func readLibrary(device: IPodDeviceSnapshot) async throws -> IPodLibrarySnapshot {
        guard await canAccessDatabase() else {
            throw IPodDatabaseAdapterError.unavailable
        }
        throw IPodDatabaseAdapterError.unsupported("iPod sync is unavailable.")
    }

    public func commitAdditiveSync(device: IPodDeviceSnapshot) async throws -> ExternalDeviceSyncSummary {
        guard await canAccessDatabase() else {
            throw IPodDatabaseAdapterError.unavailable
        }
        throw IPodDatabaseAdapterError.unsupported("iPod sync is unavailable.")
    }
}

public protocol IPodDeviceDiscovering: Sendable {
    func discoverMountedDevices() async -> [IPodDeviceSnapshot]
}

public struct MountedIPodDeviceDiscovery: IPodDeviceDiscovering {
    public init() {}

    public func discoverMountedDevices() async -> [IPodDeviceSnapshot] {
        #if os(macOS)
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIdentifierKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard isClassicIPodVolume(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let volumeName = values?.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceName = volumeName?.isEmpty == false ? volumeName! : "iPod"
            let deviceID = [
                "classic-ipod",
                values?.volumeIdentifier.map(String.init(describing:)) ?? url.path
            ].joined(separator: "|")
            let totalCapacity = Int64(values?.volumeTotalCapacity ?? 0)
            let freeCapacity = Int64(values?.volumeAvailableCapacity ?? 0)

            return IPodDeviceSnapshot(
                deviceID: deviceID,
                name: deviceName,
                modelIdentifier: nil,
                mountURL: url,
                totalCapacity: totalCapacity,
                freeCapacity: freeCapacity,
                supportState: .supported
            )
        }
        #else
        return []
        #endif
    }

    private func isClassicIPodVolume(_ url: URL) -> Bool {
        let databaseURL = url
            .appendingPathComponent("iPod_Control", isDirectory: true)
            .appendingPathComponent("iTunes", isDirectory: true)
            .appendingPathComponent("iTunesDB", isDirectory: false)
        return FileManager.default.fileExists(atPath: databaseURL.path)
    }
}
