import Combine
import Foundation

public enum ToastStyle: String, Sendable {
    case success
    case info
    case warning
    case error
}

public struct ToastAction {
    public let title: String
    public let handler: () -> Void

    public init(title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }
}

public struct ToastPayload: Identifiable {
    public let id: UUID
    public let style: ToastStyle
    public let iconSystemName: String
    public let title: String
    public let message: String?
    public let action: ToastAction?
    public let duration: TimeInterval
    public let isPersistent: Bool
    public let dedupeKey: String?

    public init(
        id: UUID = UUID(),
        style: ToastStyle,
        iconSystemName: String,
        title: String,
        message: String? = nil,
        action: ToastAction? = nil,
        duration: TimeInterval = 2.6,
        isPersistent: Bool = false,
        dedupeKey: String? = nil
    ) {
        self.id = id
        self.style = style
        self.iconSystemName = iconSystemName
        self.title = title
        self.message = message
        self.action = action
        self.duration = duration
        self.isPersistent = isPersistent
        self.dedupeKey = dedupeKey
    }
}

@MainActor
public final class ToastCenter: ObservableObject {
    @Published public private(set) var currentToast: ToastPayload?

    private var queue: [ToastPayload] = []
    private var autoDismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ toast: ToastPayload) {
        if isDuplicate(toast) {
            return
        }

        queue.append(toast)
        drainQueueIfNeeded()
    }

    public func dismissCurrent() {
        guard let toast = currentToast else { return }
        dismiss(id: toast.id)
    }

    public func dismiss(id: UUID) {
        guard currentToast?.id == id else {
            queue.removeAll { $0.id == id }
            return
        }

        autoDismissTask?.cancel()
        autoDismissTask = nil
        currentToast = nil
        drainQueueIfNeeded()
    }

    public func triggerAction(for toastID: UUID) {
        guard currentToast?.id == toastID else { return }
        let action = currentToast?.action
        dismiss(id: toastID)
        action?.handler()
    }

    private func drainQueueIfNeeded() {
        guard currentToast == nil else { return }
        guard !queue.isEmpty else { return }

        let toast = queue.removeFirst()
        currentToast = toast

        guard !toast.isPersistent else { return }

        autoDismissTask?.cancel()
        autoDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            } catch {
                return
            }
            self?.dismiss(id: toast.id)
        }
    }

    private func isDuplicate(_ toast: ToastPayload) -> Bool {
        guard let dedupeKey = toast.dedupeKey, !dedupeKey.isEmpty else { return false }

        if currentToast?.dedupeKey == dedupeKey {
            return true
        }

        return queue.contains { $0.dedupeKey == dedupeKey }
    }
}
