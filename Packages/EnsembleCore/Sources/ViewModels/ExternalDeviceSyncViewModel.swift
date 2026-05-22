import Combine
import Foundation

@MainActor
public final class ExternalDeviceSyncViewModel: ObservableObject {
    @Published public private(set) var devices: [ExternalDevice] = []
    @Published public private(set) var syncSummaries: [String: ExternalDeviceSyncSummary] = [:]
    @Published public private(set) var syncingDeviceIDs: Set<String> = []

    private let syncService: ExternalDeviceSyncService

    public init(syncService: ExternalDeviceSyncService) {
        self.syncService = syncService

        syncService.$devices
            .removeDuplicates()
            .assign(to: &$devices)

        syncService.$syncSummaries
            .assign(to: &$syncSummaries)

        syncService.$syncingDeviceIDs
            .assign(to: &$syncingDeviceIDs)
    }

    public func startMonitoring() async {
        syncService.startAutomaticMonitoring()
        await refresh()
    }

    public func refresh() async {
        await syncService.refreshMountedDevices(syncDiscoveredDevices: false)
    }

    public func syncNow(deviceID: String) async {
        await syncService.syncDevice(id: deviceID)
    }

    public func summary(for deviceID: String) -> ExternalDeviceSyncSummary? {
        syncSummaries[deviceID]
    }
}
