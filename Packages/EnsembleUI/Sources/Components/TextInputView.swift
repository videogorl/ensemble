import SwiftUI

/// A pushed view with a text field for name input.
/// Used instead of `.alert()` + `TextField` to avoid the iOS 26 ScrollPocketCollectorModel
/// feedback loop: pushed views replace the root navigation bar (which has active
/// scroll pocket tracking) with their own inline-title bar (no collapse tracking),
/// so the keyboard can appear without triggering the cascade.
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
        Form {
            if !message.isEmpty {
                Section {
                    Text(message)
                        .foregroundColor(.secondary)
                }
            }
            Section {
                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismissAfterKeyboard() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            text = initialText
            // Delay focus so the push animation completes first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    /// Dismiss keyboard first, then pop — prevents the keyboard dismissal animation
    /// from overlapping with the root navigation bar restoration, which triggers
    /// the iOS 26 ScrollPocket feedback loop.
    private func dismissAfterKeyboard() {
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dismiss()
            onSubmit(trimmed)
        }
    }
}
