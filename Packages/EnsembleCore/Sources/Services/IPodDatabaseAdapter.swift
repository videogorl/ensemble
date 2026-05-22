import Foundation

public enum IPodDatabaseAdapterError: LocalizedError, Equatable {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        }
    }
}

public protocol IPodDatabaseAdapting: Sendable {
    func readLibrary(device: IPodDeviceSnapshot) async throws -> IPodLibrarySnapshot
    func commitAdditiveSync(device: IPodDeviceSnapshot) async throws -> ExternalDeviceSyncSummary
}

/// Placeholder boundary for the libgpod/helper implementation.
///
/// Classic iPods require database writes, not plain file copies. This adapter keeps
/// that native dependency isolated so Ensemble can ship the mapped-only sync planner
/// and UI while hardware-backed libgpod integration is added behind one seam.
public struct UnsupportedIPodDatabaseAdapter: IPodDatabaseAdapting {
    public init() {}

    public func readLibrary(device: IPodDeviceSnapshot) async throws -> IPodLibrarySnapshot {
        throw IPodDatabaseAdapterError.unsupported(
            "Classic iPod database access requires the libgpod helper."
        )
    }

    public func commitAdditiveSync(device: IPodDeviceSnapshot) async throws -> ExternalDeviceSyncSummary {
        throw IPodDatabaseAdapterError.unsupported(
            "Classic iPod database writes require the libgpod helper."
        )
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
