import Foundation

@MainActor
final class DebouncedTaskRegistry<Key: Hashable> {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var entries: [Key: Entry] = [:]

    func schedule(
        key: Key,
        delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) {
        schedule(
            key: key,
            delayNanoseconds: UInt64(max(0, delay) * 1_000_000_000),
            operation: operation
        )
    }

    func schedule(
        key: Key,
        delayNanoseconds: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        entries[key]?.task.cancel()

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }

            defer { self.removeEntry(key: key, id: id) }
            await operation()
        }
        entries[key] = Entry(id: id, task: task)
    }

    func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
    }

    func cancel(key: Key) {
        entries[key]?.task.cancel()
        entries.removeValue(forKey: key)
    }

    func cancel(where shouldCancel: (Key) -> Bool) {
        let keysToCancel = entries.keys.filter(shouldCancel)
        for key in keysToCancel {
            cancel(key: key)
        }
    }

    private func removeEntry(key: Key, id: UUID) {
        guard entries[key]?.id == id else { return }
        entries.removeValue(forKey: key)
    }
}
