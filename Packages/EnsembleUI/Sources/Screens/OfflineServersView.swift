import EnsembleCore
import SwiftUI

public struct OfflineServersView: View {
    @StateObject private var viewModel: OfflineServersViewModel

    public init() {
        self._viewModel = StateObject(
            wrappedValue: DependencyContainer.shared.makeOfflineServersViewModel()
        )
    }

    public var body: some View {
        List {
            if viewModel.sections.isEmpty {
                Section {
                    Text("No enabled libraries")
                        .foregroundColor(.secondary)
                } footer: {
                    Text("Enable library sync first in Music Sources to make server downloads available.")
                }
            } else {
                ForEach(viewModel.sections) { section in
                    Section {
                        ForEach(section.libraries) { library in
                            Toggle(isOn: Binding(
                                get: {
                                    viewModel.isLibraryEnabled(sourceCompositeKey: library.sourceCompositeKey)
                                },
                                set: { enabled in
                                    Task {
                                        await viewModel.setLibraryEnabled(
                                            sourceCompositeKey: library.sourceCompositeKey,
                                            title: library.title,
                                            isEnabled: enabled
                                        )
                                    }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.title)
                                    Text(library.sourceCompositeKey)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            if let subtitle = section.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Servers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await viewModel.refresh()
        }
    }
}
