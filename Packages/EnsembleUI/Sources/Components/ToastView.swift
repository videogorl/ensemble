import EnsembleCore
import SwiftUI

public struct ToastHostView: View {
    @ObservedObject var toastCenter: ToastCenter
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat

    public init(
        toastCenter: ToastCenter,
        horizontalPadding: CGFloat = 16,
        bottomPadding: CGFloat = 16
    ) {
        self.toastCenter = toastCenter
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
    }

    public var body: some View {
        Group {
            if let toast = toastCenter.currentToast {
                ToastBannerView(toast: toast, toastCenter: toastCenter)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: toastCenter.currentToast?.id)
    }
}

public struct ToastBannerView: View {
    let toast: ToastPayload
    let toastCenter: ToastCenter

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: toast.iconSystemName)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let action = toast.action {
                Button(action.title) {
                    toastCenter.triggerAction(for: toast.id)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if toast.tapHandler != nil {
                toastCenter.triggerTap(for: toast.id)
                return
            }
            // Allow full-toast dismissal only for non-action toasts.
            guard toast.action == nil else { return }
            toastCenter.dismiss(id: toast.id)
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch toast.style {
        case .success:
            return .green
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var borderColor: Color {
        switch toast.style {
        case .success:
            return .green.opacity(0.35)
        case .info:
            return .blue.opacity(0.35)
        case .warning:
            return .orange.opacity(0.35)
        case .error:
            return .red.opacity(0.4)
        }
    }
}
