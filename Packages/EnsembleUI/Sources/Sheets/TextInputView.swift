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
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

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
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        guard !trimmed.isEmpty else { return }
        dismiss()
        onSubmit(trimmed)
    }
}
