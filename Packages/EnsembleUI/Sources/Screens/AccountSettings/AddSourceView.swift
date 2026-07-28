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
                    Label {
                        Text("Plex")
                    } icon: {
                        Image("PlexSourceIcon")
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, 3)
                            .frame(width: 30, height: 30)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }

                #if os(iOS)
                if #available(iOS 18, *) {
                    Button {
                        Task { await addAppleMusic() }
                    } label: {
                        HStack {
                            Label {
                                Text("Apple Music")
                            } icon: {
                                Image("AppleMusicSourceIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                            }
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
                    Label {
                        Text("Apple Music Requires iOS 18")
                    } icon: {
                        Image("AppleMusicSourceIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    }
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
        .if(!isEmbedded) { view in
            view.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
