import Combine
import Foundation

@MainActor
enum ViewModelNotificationObserver {
    static func observe(
        _ name: Notification.Name,
        debounce: DispatchQueue.SchedulerTimeType.Stride,
        storingIn cancellables: inout Set<AnyCancellable>,
        action: @escaping @MainActor () async -> Void
    ) {
        NotificationCenter.default.publisher(for: name)
            .debounce(for: debounce, scheduler: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in
                    await action()
                }
            }
            .store(in: &cancellables)
    }
}
