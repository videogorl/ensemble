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
                    .id(slotID(edge: .leading, index: index))
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
                    .id(slotID(edge: .trailing, index: index))
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
        if let value, let existingIndex = indexOfAction(value, edge: edge, excluding: index) {
            setSlot(value, edge: edge, index: index)
            setSlot(currentValue, edge: edge, index: existingIndex)
        } else {
            setSlot(value, edge: edge, index: index)
        }
        persistLayout()
    }

    private func indexOfAction(_ action: TrackSwipeAction, edge: TrackSwipeEdge, excluding excludedIndex: Int) -> Int? {
        for (index, candidate) in slots(edge: edge).enumerated() {
            if index == excludedIndex {
                continue
            }
            if candidate == action {
                return index
            }
        }
        return nil
    }

    private func slotID(edge: TrackSwipeEdge, index: Int) -> String {
        "\(edge.rawValue)-\(index)"
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

    private func slots(edge: TrackSwipeEdge) -> [TrackSwipeAction?] {
        switch edge {
        case .leading:
            return leadingSlots
        case .trailing:
            return trailingSlots
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
