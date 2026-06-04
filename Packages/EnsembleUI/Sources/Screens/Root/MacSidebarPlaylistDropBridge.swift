#if os(macOS)
import AppKit
import SwiftUI

/// AppKit drop bridge for sidebar playlist rows so macOS keeps drag targeting reliable inside NavigationSplitView.
struct MacSidebarPlaylistDropBridge: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (MediaDragPayload) -> Bool

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes(MediaDragPayload.pasteboardTypes)
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.registerForDraggedTypes(MediaDragPayload.pasteboardTypes)
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        var onTargetedChange: ((Bool) -> Void)?
        var onDrop: ((MediaDragPayload) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard MediaDragPayload.canLoad(from: sender.draggingPasteboard) else {
                return []
            }
            onTargetedChange?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            MediaDragPayload.canLoad(from: sender.draggingPasteboard) ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargetedChange?(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargetedChange?(false)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            MediaDragPayload.canLoad(from: sender.draggingPasteboard)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { onTargetedChange?(false) }
            guard let payload = MediaDragPayload.load(from: sender.draggingPasteboard) else {
                EnsembleLogger.debug(
                    "Sidebar playlist AppKit drop failed: payload unresolved providerTypes=\(MediaDragPayload.debugRegisteredTypeIdentifiers(for: sender.draggingPasteboard))"
                )
                return false
            }
            return onDrop?(payload) ?? false
        }
    }
}
#endif
