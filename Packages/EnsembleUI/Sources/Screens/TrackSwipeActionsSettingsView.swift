import EnsembleCore
import SwiftUI

public struct TrackSwipeActionsSettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    @State private var leadingSlots: [TrackSwipeAction?] = []
    @State private var trailingSlots: [TrackSwipeAction?] = []
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }

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
                    errorMessage = nil
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
        if let value, isDuplicate(value, excluding: (edge: edge, index: index)) {
            errorMessage = "\"\(value.title)\" is already assigned to another slot."
            return
        }

        switch edge {
        case .leading:
            leadingSlots[index] = value
        case .trailing:
            trailingSlots[index] = value
        }

        errorMessage = nil
        persistLayout()
    }

    private func isDuplicate(_ action: TrackSwipeAction, excluding location: (edge: TrackSwipeEdge, index: Int)) -> Bool {
        for (index, candidate) in leadingSlots.enumerated() {
            if location.edge == .leading && location.index == index {
                continue
            }
            if candidate == action {
                return true
            }
        }
        for (index, candidate) in trailingSlots.enumerated() {
            if location.edge == .trailing && location.index == index {
                continue
            }
            if candidate == action {
                return true
            }
        }
        return false
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
