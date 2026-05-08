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
        #if os(iOS)
        iOSContent
            .onAppear {
                text = initialText
            }
            .onDisappear {
                isFocused = false
            }
        #else
        navigationContainer
            .onAppear {
                text = initialText
            }
        #endif
    }

    #if os(iOS)
    private var iOSContent: some View {
        VStack(spacing: 0) {
            editorHeader

            Form {
                compactFormRows
            }
        }
    }

    private var editorHeader: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .foregroundColor(EnsembleDesign.Color.primaryText)

            HStack {
                Button("Cancel") {
                    isFocused = false
                    dismiss()
                }
                .disabled(isSubmitting)

                Spacer()

                if isSubmitting {
                    ProgressView()
                } else {
                    Button(actionTitle) { submit() }
                        .font(.body.weight(.semibold))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, EnsembleDesign.Spacing.lg)
        .padding(.vertical, EnsembleDesign.Spacing.md)
        .background(.bar)
    }
    #endif

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
