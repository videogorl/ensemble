import Foundation

public struct PinMutationWorkflowResult: Equatable {
    public let changed: Bool

    public init(changed: Bool) {
        self.changed = changed
    }
}

/// Shared policy boundary for user-initiated pin mutations.
///
/// Pins are local, reversible preference mutations, so the current toast policy is intentionally
/// silent. Views should still route pin/unpin through this workflow so no-op and batch behavior
/// stays consistent across context menus, detail headers, sidebars, and pinned lists.
@MainActor
public final class PinMutationWorkflow {
    private let pinManager: PinManager

    public init(pinManager: PinManager) {
        self.pinManager = pinManager
    }

    public var pinnedItems: [PinnedItem] {
        pinManager.pinnedItems
    }

    public func isPinned(id: String, sourceKey: String) -> Bool {
        pinManager.isPinned(id: id, sourceKey: sourceKey)
    }

    @discardableResult
    public func pin(id: String, sourceKey: String, type: PinnedItemType, title: String) -> PinMutationWorkflowResult {
        guard !pinManager.isPinned(id: id, sourceKey: sourceKey) else {
            return PinMutationWorkflowResult(changed: false)
        }

        pinManager.pin(id: id, sourceKey: sourceKey, type: type, title: title)
        return PinMutationWorkflowResult(changed: true)
    }

    @discardableResult
    public func unpin(id: String, sourceKey: String) -> PinMutationWorkflowResult {
        guard pinManager.isPinned(id: id, sourceKey: sourceKey) else {
            return PinMutationWorkflowResult(changed: false)
        }

        pinManager.unpin(id: id, sourceKey: sourceKey)
        return PinMutationWorkflowResult(changed: true)
    }

    @discardableResult
    public func togglePin(
        id: String,
        sourceKey: String,
        type: PinnedItemType,
        title: String,
        isPinned: Bool? = nil
    ) -> PinMutationWorkflowResult {
        let currentlyPinned = isPinned ?? pinManager.isPinned(id: id, sourceKey: sourceKey)
        if currentlyPinned {
            return unpin(id: id, sourceKey: sourceKey)
        }

        return pin(id: id, sourceKey: sourceKey, type: type, title: title)
    }

    @discardableResult
    public func pinAll(
        items: [(id: String, sourceKey: String, type: PinnedItemType, title: String)]
    ) -> PinMutationWorkflowResult {
        let before = pinManager.pinnedItems
        pinManager.pinAll(items: items)
        return PinMutationWorkflowResult(changed: before != pinManager.pinnedItems)
    }

    @discardableResult
    public func unpinAll(identities: Set<String>) -> PinMutationWorkflowResult {
        let before = pinManager.pinnedItems
        pinManager.unpinAll(identities: identities)
        return PinMutationWorkflowResult(changed: before != pinManager.pinnedItems)
    }

    public func areAllPinned(identities: Set<String>) -> Bool {
        pinManager.areAllPinned(identities: identities)
    }

    public func updateTitle(id: String, sourceKey: String, title: String) {
        pinManager.updateTitle(id: id, sourceKey: sourceKey, title: title)
    }

    public func reorder(identities: [String]) {
        pinManager.reorder(identities: identities)
    }
}
