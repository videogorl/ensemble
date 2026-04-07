import EnsembleCore
import SwiftUI

/// A focused text-input editor used for short rename flows.
/// On iPhone this is presented in a full-screen cover so the underlying
/// NavigationStack or searchable drawer stays out of the keyboard layout pass.
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
        VStack(spacing: 0) {
            // Custom Navigation Bar to avoid iOS 26 UIObservationTrackingFeedbackLoopDetected
            // when a keyboard pushes a sheet with a real UINavigationBar.
            HStack {
                Button("Cancel") { dismissAfterKeyboard() }
                    .foregroundColor(.accentColor)
                Spacer()
                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
                Button(actionTitle) { submit() }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .padding()
            #if os(iOS)
            .background(Color(uiColor: .secondarySystemGroupedBackground).ignoresSafeArea(edges: .top))
            #else
            .background(Color.secondary.opacity(0.1))
            #endif
            
            Divider()

            VStack(spacing: 20) {
                if !message.isEmpty {
                    Text(message)
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .padding()
                    #if os(iOS)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    #else
                    .background(Color.secondary.opacity(0.1))
                    #endif
                    .cornerRadius(10)
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 20)
        }
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
        .onAppear {
            text = initialText
            // Delay focus so the modal presentation settles before the keyboard animates.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
    }

    /// Dismiss keyboard first, then dismiss the modal so the keyboard animation
    /// doesn't overlap with the presentation teardown.
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
