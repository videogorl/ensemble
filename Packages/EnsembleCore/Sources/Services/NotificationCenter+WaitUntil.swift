import Foundation

public extension NotificationCenter {
    /// Returns true as soon as `condition` holds, checking once after subscribing (so a change
    /// that already happened is not missed) and again after each `name` notification. Returns
    /// false when `timeout` elapses first.
    @MainActor
    func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        after name: Notification.Name,
        timeout: Duration
    ) async -> Bool {
        let notifications = self.notifications(named: name)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                if condition() { return true }
                for await _ in notifications where condition() { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
