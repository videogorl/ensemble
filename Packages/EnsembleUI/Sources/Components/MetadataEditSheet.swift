import EnsembleCore
import SwiftUI

struct MetadataEditSheet: View {
    enum ItemKind {
        case track
        case album
        case artist

        var title: String {
            switch self {
            case .track: return "Edit Track"
            case .album: return "Edit Album"
            case .artist: return "Edit Artist"
            }
        }

        var fieldLabel: String {
            switch self {
            case .track: return "Track title"
            case .album: return "Album title"
            case .artist: return "Artist name"
            }
        }
    }

    let kind: ItemKind
    let currentTitle: String
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var titleText: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(
        kind: ItemKind,
        currentTitle: String,
        onSave: @escaping (String) async throws -> Void
    ) {
        self.kind = kind
        self.currentTitle = currentTitle
        self.onSave = onSave
        _titleText = State(initialValue: currentTitle)
    }

    var body: some View {
        navigationContainer
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFocused = true
                }
            }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack { formContent }
        } else {
            NavigationView { formContent }
                #if os(iOS)
                .navigationViewStyle(.stack)
                #endif
        }
    }

    private var formContent: some View {
        Form {
            Section {
                TextField(kind.fieldLabel, text: $titleText)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
            } footer: {
                Text("Changes are sent directly to Plex and then refreshed locally.")
            }
        }
        .navigationTitle(kind.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSaving)
            }

            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        submit()
                    }
                    .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true

        Task {
            do {
                try await onSave(trimmed)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }
}
