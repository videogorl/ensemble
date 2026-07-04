import SwiftUI

/// A focused text-input editor used for short sheet-based text flows.
/// Use native alerts for playlist rename; keep this for form-style editors.
struct TextInputView: View {
    let title: String
    var message: String = ""
    let placeholder: String
    var initialText: String = ""
    let actionTitle: String
    let onSubmit: (String) async throws -> Void

    @State private var text = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        title: String,
        message: String = "",
        placeholder: String,
        initialText: String = "",
        actionTitle: String,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.initialText = initialText
        self.actionTitle = actionTitle
        self.onSubmit = { text in onSubmit(text) }
    }

    init(
        title: String,
        message: String = "",
        placeholder: String,
        initialText: String = "",
        actionTitle: String,
        onSubmit: @escaping (String) async throws -> Void
    ) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.initialText = initialText
        self.actionTitle = actionTitle
        self.onSubmit = onSubmit
    }

    var body: some View {
        formContent
            .nativeSheetNavigationContainer()
            .onAppear {
                text = initialText
            }
            #if os(iOS)
            .onDisappear {
                isFocused = false
            }
            #endif
    }

    private var formContent: some View {
        EnsembleAdaptiveUtilityScaffold(title: title) {
            Form {
                compactFormRows
            }
        } regularContent: {
            if !message.isEmpty {
                EnsembleUtilityCardSection {
                    EnsembleUtilityCardRow {
                        Text(message)
                            .foregroundColor(EnsembleDesign.Color.secondaryText)
                    }
                }
            }

            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    textField
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    isFocused = false
                    dismiss()
                }
                    .disabled(isSubmitting)
            }

            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView()
                } else {
                    Button(actionTitle) { submit() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        #endif
    }

    @ViewBuilder
    private var compactFormRows: some View {
        if !message.isEmpty {
            Section {
                Text(message)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
        }

        Section {
            textField
        }
    }

    private var textField: some View {
        TextField(placeholder, text: $text)
            .focused($isFocused)
            .submitLabel(.done)
            .onSubmit { submit() }
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return }
        isSubmitting = true

        Task {
            do {
                try await onSubmit(trimmed)
                await MainActor.run {
                    isFocused = false
                    dismiss()
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                }
            }
        }
    }
}

extension View {
    func metadataEditorSheet(request: Binding<ContextMenuMetadataEditorRequest?>) -> some View {
        sheet(item: request) { request in
            TextInputView(
                title: request.kind.title,
                message: "Changes are sent directly to Plex and then refreshed locally.",
                placeholder: request.kind.fieldLabel,
                initialText: request.currentTitle,
                actionTitle: "Save",
                onSubmit: request.onSave
            )
        }
    }
}
