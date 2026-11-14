import EnsembleCore
import SwiftUI

public struct VisualizerSettingsView: View {
    @Environment(DependencyContainer.self) private var dependencies

    public init() {}

    public var body: some View {
        @Bindable var settingsManager = dependencies.settingsManager
        List {
            Section {
                Toggle("Visualizer", isOn: $settingsManager.visualizerEnabled)
                    .accessibilityIdentifier("settings.visualizer.enabled")
            } footer: {
                Text("Replaces the Now Playing background with a visualizer that moves with the music. The Visualizer button in Now Playing turns it on and off too. Not available for Apple Music.")
            }

            Section {
                Picker("Style", selection: $settingsManager.visualizerStyle) {
                    ForEach(VisualizerStyle.allCases) { style in
                        VStack(alignment: .leading) {
                            Text(style.title)
                            Text(style.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("settings.visualizer.style")
            } header: {
                Text("Style")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Visualizer")
    }
}
