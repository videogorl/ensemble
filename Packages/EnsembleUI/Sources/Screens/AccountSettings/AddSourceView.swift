import EnsembleCore
import SwiftUI
#if os(iOS)
import MusicKit
#endif

public struct AddSourceView: View {
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    private let syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isAddingAppleMusic = false
    private let isEmbedded: Bool

    public init(embedded: Bool = false) {
        self.isEmbedded = embedded
    }

    public var body: some View {
        Group {
            if isEmbedded {
                content
            } else {
                content.nativeSheetNavigationContainer()
            }
        }
    }

    private var content: some View {
        List {
            Section {
                NavigationLink {
                    AddPlexAccountView(embedded: true)
                } label: {
                    Label("Plex", systemImage: "play.rectangle.on.rectangle")
                }

                #if os(iOS)
                if #available(iOS 18, *) {
                    Button {
                        Task { await addAppleMusic() }
                    } label: {
                        HStack {
                            Label("Apple Music", systemImage: "apple.logo")
                            Spacer()
                            if isAddingAppleMusic {
                                ProgressView()
                            } else if accountManager.isAppleMusicEnabled {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(accountManager.isAppleMusicEnabled || isAddingAppleMusic)
                } else {
                    Label("Apple Music Requires iOS 18", systemImage: "apple.logo")
                        .foregroundStyle(.secondary)
                }
                #endif
            } footer: {
                #if os(iOS)
                Text("Apple Music stays on this device and requires an active Apple Music subscription.")
                #else
                Text("Apple Music sources are available on iPhone and iPad.")
                #endif
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Source")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .opacity(isEmbedded ? 0 : 1)
                    .disabled(isEmbedded)
                    .accessibilityHidden(isEmbedded)
            }
        }
    }

    #if os(iOS)
    @available(iOS 18, *)
    private func addAppleMusic() async {
        isAddingAppleMusic = true
        defer { isAddingAppleMusic = false }
        guard await MusicAuthorization.request() == .authorized else {
            errorMessage = "Allow Apple Music access in Settings to add this source."
            return
        }

        do {
            let subscription = try await MusicSubscription.current
            guard subscription.canPlayCatalogContent else {
                errorMessage = "An active Apple Music subscription is required."
                return
            }
            accountManager.setAppleMusicEnabled(true)
            syncCoordinator.refreshProviders()
            await syncCoordinator.sync(source: .appleMusic)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif
}
