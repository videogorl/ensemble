import EnsembleCore
import SwiftUI
#if os(iOS)
import MusicKit
#endif

public struct AddSourceView: View {
    @ObservedObject private var accountManager = DependencyContainer.shared.accountManager
    @ObservedObject private var syncCoordinator = DependencyContainer.shared.syncCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isAddingAppleMusic = false
    @State private var appleMusicSetupRequestID: UUID?
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
                        appleMusicSetupRequestID = UUID()
                    } label: {
                        HStack {
                            Label {
                                Text(appleMusicSyncNeedsRetry ? "Retry Apple Music" : "Apple Music")
                            } icon: {
                                Image("AppleMusicSourceIcon")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                            }
                            Spacer()
                            if isAddingAppleMusic || isAppleMusicSyncing {
                                ProgressView()
                            } else if appleMusicSyncNeedsRetry {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.secondary)
                            } else if accountManager.isAppleMusicEnabled {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(
                        isAddingAppleMusic
                            || isAppleMusicSyncing
                            || (accountManager.isAppleMusicEnabled && !appleMusicSyncNeedsRetry)
                    )
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

            if let displayedErrorMessage {
                Section {
                    Text(displayedErrorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Source")
        #if os(iOS)
        .task(id: appleMusicSetupRequestID) {
            guard appleMusicSetupRequestID != nil else { return }
            defer { appleMusicSetupRequestID = nil }
            guard #available(iOS 18, *) else { return }
            await addAppleMusic()
        }
        .onReceive(syncCoordinator.$sourceStatuses) { statuses in
            guard case .lastSynced = statuses[.appleMusic]?.syncStatus else { return }
            errorMessage = nil
        }
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
        errorMessage = nil
        isAddingAppleMusic = true
        defer { isAddingAppleMusic = false }
        let authorization = await MusicAuthorization.request()
        guard !Task.isCancelled else { return }
        guard authorization == .authorized else {
            errorMessage = "Allow Apple Music access in Settings to add this source."
            return
        }

        do {
            let subscription = try await MusicSubscription.current
            guard !Task.isCancelled else { return }
            guard subscription.canPlayCatalogContent else {
                errorMessage = "An active Apple Music subscription is required."
                return
            }
            accountManager.setAppleMusicEnabled(true)
            syncCoordinator.refreshProviders()
            let outcome = await syncCoordinator.sync(source: .appleMusic)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success:
                dismiss()
            case .failure(let message):
                if appleMusicSyncErrorMessage == nil {
                    errorMessage = message
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var appleMusicSyncNeedsRetry: Bool {
        accountManager.isAppleMusicEnabled
            && (accountManager.isAppleMusicInitialSyncPending || appleMusicSyncErrorMessage != nil)
    }

    private var isAppleMusicSyncing: Bool {
        guard case .syncing = syncCoordinator.sourceStatuses[.appleMusic]?.syncStatus else { return false }
        return true
    }

    private var appleMusicSyncErrorMessage: String? {
        guard case .error(let message) = syncCoordinator.sourceStatuses[.appleMusic]?.syncStatus else { return nil }
        return message
    }

    #endif

    private var displayedErrorMessage: String? {
        #if os(iOS)
        appleMusicSyncErrorMessage ?? errorMessage
        #else
        errorMessage
        #endif
    }
}
