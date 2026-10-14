import EnsembleCore
import SwiftUI

public struct NowPlayingActionsSettingsView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public init() {}

    public var body: some View {
        List {
            Section {
                ForEach(0..<NowPlayingSecondaryLayout.slotCount, id: \.self) { index in
                    Picker("Slot \(index + 1)", selection: slotBinding(index)) {
                        Text("None").tag(Optional<NowPlayingSecondaryAction>.none)
                        ForEach(NowPlayingSecondaryAction.allCases) { action in
                            Label(action.title, systemImage: action.systemImage).tag(Optional(action))
                        }
                    }
                    .accessibilityIdentifier("settings.nowPlayingActions.slot.\(index)")
                }
            } header: {
                Text("Secondary Actions")
            } footer: {
                Text("Empty slots collapse. More Actions always includes every available action. Selecting an assigned action swaps its slots.")
            }
            Section {
                Button("Reset to Defaults") {
                    settingsManager.resetNowPlayingSecondaryLayoutToDefaults()
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Now Playing Actions")
    }

    private func slotBinding(_ index: Int) -> Binding<NowPlayingSecondaryAction?> {
        Binding(
            get: { settingsManager.nowPlayingSecondaryLayout.slots[index] },
            set: { settingsManager.setNowPlayingSecondaryAction($0, index: index) }
        )
    }
}
