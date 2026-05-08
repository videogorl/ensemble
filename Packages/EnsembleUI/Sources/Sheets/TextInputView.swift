import SwiftUI

/// A focused text-input editor used for short rename flows.
/// Presenters decide whether this lives in a normal sheet or a specialized
/// root-owned presenter based on the surrounding container.
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
        navigationContainer
            .onAppear {
                text = initialText
            }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationStack {
                formContent
            }
        } else {
            NavigationView {
                formContent
            }
            #if os(iOS)
            .navigationViewStyle(.stack)
            #endif
        }
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
                Button("Cancel") { dismiss() }
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
