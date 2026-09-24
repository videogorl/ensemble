#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacSidebarPlaylistDropRegistry {
    static let shared = MacSidebarPlaylistDropRegistry()

    private struct Entry {
        var frame: NSRect
        var canAccept: (MediaDragPayload) -> Bool
        var onTargetedChange: (Bool) -> Void
        var onDisabledChange: (Bool) -> Void
        var onDrop: (MediaDragPayload) -> Bool
        var isDisabled: Bool
    }

    private var entries: [UUID: Entry] = [:]
    private var activePayload: MediaDragPayload?
    private var targetedID: UUID?

    func update(
        id: UUID,
        frame: NSRect,
        canAccept: @escaping (MediaDragPayload) -> Bool,
        onTargetedChange: @escaping (Bool) -> Void,
        onDisabledChange: @escaping (Bool) -> Void,
        onDrop: @escaping (MediaDragPayload) -> Bool
    ) {
        let isDisabled = activePayload.map { !canAccept($0) } ?? false
        let previousDisabled = entries[id]?.isDisabled
        entries[id] = Entry(
            frame: frame,
            canAccept: canAccept,
            onTargetedChange: onTargetedChange,
            onDisabledChange: onDisabledChange,
            onDrop: onDrop,
            isDisabled: isDisabled
        )
        if previousDisabled != isDisabled {
            onDisabledChange(isDisabled)
        }
    }

    func remove(id: UUID) {
        if targetedID == id {
            entries[id]?.onTargetedChange(false)
            targetedID = nil
        }
        entries[id]?.onDisabledChange(false)
        entries.removeValue(forKey: id)
    }

    func beginDragging(_ payload: MediaDragPayload) {
        activePayload = payload
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.isDisabled = !entry.canAccept(payload)
            entries[id] = entry
            entry.onDisabledChange(entry.isDisabled)
        }
    }

    func updateTarget(at screenPoint: NSPoint) {
        guard let activePayload else {
            setTarget(nil)
            return
        }
        setTarget(entries.first {
            $0.value.frame.contains(screenPoint) && $0.value.canAccept(activePayload)
        }?.key)
    }

    func performDrop(at screenPoint: NSPoint) -> Bool {
        guard let payload = activePayload,
              let entry = entries.first(where: {
                  $0.value.frame.contains(screenPoint) && $0.value.canAccept(payload)
              })?.value else {
            return false
        }
        return entry.onDrop(payload)
    }

    func endDragging() {
        setTarget(nil)
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.isDisabled = false
            entries[id] = entry
            entry.onDisabledChange(false)
        }
        activePayload = nil
    }

    private func setTarget(_ id: UUID?) {
        guard targetedID != id else { return }
        if let targetedID {
            entries[targetedID]?.onTargetedChange(false)
        }
        targetedID = id
        if let id {
            entries[id]?.onTargetedChange(true)
        }
    }
}

/// Registers a sidebar playlist row with the macOS local-drag fallback.
/// SwiftUI's native outline view claims same-window drags before row-level
/// destinations receive them, so the source session resolves the registered
/// row at its final screen location.
struct MacSidebarPlaylistDropBridge: NSViewRepresentable {
    @Binding var isTargeted: Bool
    @Binding var isDisabled: Bool
    let canAccept: (MediaDragPayload) -> Bool
    let onDrop: (MediaDragPayload) -> Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        configure(view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        configure(view)
        view.updateRegistration()
    }

    private func configure(_ view: AnchorView) {
        view.canAccept = canAccept
        view.onTargetedChange = { isTargeted = $0 }
        view.onDisabledChange = { isDisabled = $0 }
        view.onDrop = onDrop
    }

    final class AnchorView: NSView {
        let registryID = UUID()
        var canAccept: ((MediaDragPayload) -> Bool)?
        var onTargetedChange: ((Bool) -> Void)?
        var onDisabledChange: ((Bool) -> Void)?
        var onDrop: ((MediaDragPayload) -> Bool)?
        private var observations: [NSObjectProtocol] = []

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setAccessibilityElement(false)
        }

        deinit {
            removeRegistration()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeRegistration()
            } else {
                observeLayoutChanges()
                updateRegistration()
            }
        }

        override func layout() {
            super.layout()
            updateRegistration()
        }

        func updateRegistration() {
            guard let window,
                  let canAccept,
                  let onTargetedChange,
                  let onDisabledChange,
                  let onDrop else {
                return
            }

            let rowWindowFrame = convert(bounds, to: nil)
            let rowScreenFrame = window.convertToScreen(rowWindowFrame)
            let visibleScreenFrame = enclosingClipView.map { clipView in
                window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
            } ?? window.frame

            MacSidebarPlaylistDropRegistry.shared.update(
                id: registryID,
                frame: rowScreenFrame.intersection(visibleScreenFrame),
                canAccept: canAccept,
                onTargetedChange: onTargetedChange,
                onDisabledChange: onDisabledChange,
                onDrop: onDrop
            )
        }

        private var enclosingClipView: NSClipView? {
            var candidate = superview
            while let current = candidate {
                if let clipView = current as? NSClipView {
                    return clipView
                }
                candidate = current.superview
            }
            return nil
        }

        private func observeLayoutChanges() {
            guard observations.isEmpty else { return }
            let center = NotificationCenter.default
            if let clipView = enclosingClipView {
                clipView.postsBoundsChangedNotifications = true
                observations.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateRegistration()
                })
            }
            if let window {
                observations.append(center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.updateRegistration()
                })
            }
        }

        private func removeRegistration() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            MacSidebarPlaylistDropRegistry.shared.remove(id: registryID)
        }
    }
}
#endif
