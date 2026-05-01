import EnsembleCore
import SwiftUI

public struct TrackSwipeActionsSettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @State private var leadingSlots: [TrackSwipeAction?] = []
    @State private var trailingSlots: [TrackSwipeAction?] = []

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(Array(leadingSlots.enumerated()), id: \.offset) { index, _ in
                    Picker("Slot \(index + 1)", selection: slotBinding(edge: .leading, index: index)) {
                        Text("None").tag(Optional<TrackSwipeAction>.none)
                        ForEach(TrackSwipeAction.allCases) { action in
                            Text(action.title).tag(Optional(action))
                        }
                    }
                }
                .onMove { indices, newOffset in
                    leadingSlots.move(fromOffsets: indices, toOffset: newOffset)
                    persistLayout()
                }
            } header: {
                Text("Leading Swipe")
            } footer: {
                Text("Slot 1 executes on full swipe.")
            }

            Section {
                ForEach(Array(trailingSlots.enumerated()), id: \.offset) { index, _ in
                    Picker("Slot \(index + 1)", selection: slotBinding(edge: .trailing, index: index)) {
                        Text("None").tag(Optional<TrackSwipeAction>.none)
                        ForEach(TrackSwipeAction.allCases) { action in
                            Text(action.title).tag(Optional(action))
                        }
                    }
                }
                .onMove { indices, newOffset in
                    trailingSlots.move(fromOffsets: indices, toOffset: newOffset)
                    persistLayout()
                }
            } header: {
                Text("Trailing Swipe")
            } footer: {
                Text("Slot 1 executes on full swipe.")
            }

            Section {
                Button("Reset to Defaults") {
                    settingsManager.resetTrackSwipeLayoutToDefaults()
                    syncFromSettings()
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Track Swipe Actions")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
            #endif
        }
        .onAppear {
            syncFromSettings()
        }
    }

    private func slotBinding(edge: TrackSwipeEdge, index: Int) -> Binding<TrackSwipeAction?> {
        Binding(
            get: {
                switch edge {
                case .leading:
                    return leadingSlots[index]
                case .trailing:
                    return trailingSlots[index]
                }
            },
            set: { newValue in
                updateSlot(edge: edge, index: index, value: newValue)
            }
        )
    }

    private func updateSlot(edge: TrackSwipeEdge, index: Int, value: TrackSwipeAction?) {
        let currentValue = slotValue(edge: edge, index: index)
        if let value, let existingLocation = location(of: value, excluding: (edge: edge, index: index)) {
            setSlot(value, edge: edge, index: index)
            setSlot(currentValue, edge: existingLocation.edge, index: existingLocation.index)
        } else {
            setSlot(value, edge: edge, index: index)
        }
        persistLayout()
    }

    private func location(of action: TrackSwipeAction, excluding location: (edge: TrackSwipeEdge, index: Int)) -> (edge: TrackSwipeEdge, index: Int)? {
        for (index, candidate) in leadingSlots.enumerated() {
            if location.edge == .leading && location.index == index {
                continue
            }
            if candidate == action {
                return (.leading, index)
            }
        }
        for (index, candidate) in trailingSlots.enumerated() {
            if location.edge == .trailing && location.index == index {
                continue
            }
            if candidate == action {
                return (.trailing, index)
            }
        }
        return nil
    }

    private func slotValue(edge: TrackSwipeEdge, index: Int) -> TrackSwipeAction? {
        switch edge {
        case .leading:
            return leadingSlots[index]
        case .trailing:
            return trailingSlots[index]
        }
    }

    private func setSlot(_ value: TrackSwipeAction?, edge: TrackSwipeEdge, index: Int) {
        switch edge {
        case .leading:
            leadingSlots[index] = value
        case .trailing:
            trailingSlots[index] = value
        }
    }

    private func persistLayout() {
        settingsManager.trackSwipeLayout = TrackSwipeLayout(leading: leadingSlots, trailing: trailingSlots)
        syncFromSettings()
    }

    private func syncFromSettings() {
        let layout = settingsManager.trackSwipeLayout
        leadingSlots = layout.leading
        trailingSlots = layout.trailing
    }
}
