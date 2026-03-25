import EnsembleCore
import SwiftUI

/// Main sheet container for iPhone-style Now Playing presentation.
/// Large-screen viewport presentation lives in `NowPlayingViewportRoot`.
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss

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
        ZStack {
            BlurredArtworkBackground(image: viewModel.artworkImage)
                .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)

            Color.black.opacity(0.4)
                .allowsHitTesting(false)
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
