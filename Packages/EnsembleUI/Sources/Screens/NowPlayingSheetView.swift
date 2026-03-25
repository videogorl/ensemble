import EnsembleCore
import SwiftUI

/// Main sheet container for iPhone-style Now Playing presentation.
/// Large-screen viewport presentation lives in `NowPlayingViewportRoot`.
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let namespace: Namespace.ID?
    private let animationID: String?
    private let dismissAction: (() -> Void)?

    public init(
        viewModel: NowPlayingViewModel,
        namespace: Namespace.ID? = nil,
        animationID: String? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.namespace = namespace
        self.animationID = animationID
        self.dismissAction = dismissAction
    }

    public var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 0) {
                dismissPill
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleDismiss()
                    }

                NowPlayingCarousel(viewModel: viewModel, currentPage: $viewModel.currentPage)
            }
        }
    }

    private var backgroundView: some View {
        // Adaptive overlay: light mode uses system background tint, dark mode uses black
        let lightOverlayColor: Color = {
            #if os(iOS)
            return Color(uiColor: .systemBackground)
            #elseif os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return .white
            #endif
        }()

        return ZStack {
            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                overlayColor: colorScheme == .dark ? .black : lightOverlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            if colorScheme == .dark {
                Color.black.opacity(0.45)
                    .allowsHitTesting(false)
            } else {
                lightOverlayColor.opacity(0.7)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private var dismissPill: some View {
        Capsule()
            .fill(Color.primary.opacity(0.3))
            .frame(width: 36, height: 5)
    }

    private func handleDismiss() {
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }
}
