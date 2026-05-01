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
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
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
                                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                                    Text(library.title)
                                    Text(library.sourceCompositeKey)
                                        .font(EnsembleDesign.Typography.cardMetadata)
                                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                            Text(section.title)
                            if let subtitle = section.subtitle {
                                Text(subtitle)
                                    .font(EnsembleDesign.Typography.cardSubtitle)
                                    .foregroundColor(EnsembleDesign.Color.secondaryText)
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
