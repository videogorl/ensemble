import EnsembleDesignTokens
import EnsembleCore
import SwiftUI

/// Shared iOS Now Playing content for native sheets.
/// macOS viewport presentation lives in `NowPlayingViewportRoot`.
public struct NowPlayingSheetView: View {
    let viewModel: NowPlayingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int

    private let dismissAction: (() -> Void)?

    public init(
        viewModel: NowPlayingViewModel,
        dismissAction: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self._currentPage = State(initialValue: viewModel.currentPage)
        self.dismissAction = dismissAction
    }

    public var body: some View {
        GeometryReader { geometry in
            let usesWideLayout = usesWideNowPlayingLayout(for: geometry.size)
            ZStack {
                backgroundView

                VStack(spacing: EnsembleDesign.Spacing.none) {
                    if !usesWideLayout {
                        Button(action: handleDismiss) {
                            dismissPill.frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Now Playing")
                    }

                    if usesWideLayout {
                        NowPlayingWidePanelLayout(
                            viewModel: viewModel,
                            currentPage: currentPageBinding,
                            dismissAction: handleDismiss,
                            centersContentInAvailableSpace: true
                        )
                    } else {
                        NowPlayingCarousel(viewModel: viewModel, currentPage: currentPageBinding)
                    }
                }
            }
        }
        .onAppear {
            currentPage = viewModel.currentPage
        }
    }

    private var currentPageBinding: Binding<Int> {
        Binding(
            get: { currentPage },
            set: { newValue in
                currentPage = newValue
                viewModel.currentPage = newValue
            }
        )
    }

    private var backgroundView: some View {
        NowPlayingBackdrop(
            viewModel: viewModel,
            consumer: .nowPlayingSheet,
            activeContentMaxWidth: nowPlayingSheetAuroraActiveContentMaxWidth,
            forceDarkPresentation: false
        )
    }

    private var nowPlayingSheetAuroraActiveContentMaxWidth: CGFloat? {
        #if os(iOS)
        return nil
        #else
        return EnsembleScaffold.NowPlaying.auroraActiveContentMaxWidth
        #endif
    }

    private var dismissPill: some View {
        Capsule()
            .fill(EnsembleDesign.Color.primaryText.opacity(EnsembleScaffold.NowPlaying.dismissPillOpacity))
            .frame(
                width: EnsembleScaffold.NowPlaying.dismissPillWidth,
                height: EnsembleScaffold.NowPlaying.dismissPillHeight
            )
    }

    private func usesWideNowPlayingLayout(for size: CGSize) -> Bool {
        let minimumWideWidth = (EnsembleScaffold.NowPlaying.viewportContentPadding * 2)
            + EnsembleScaffold.NowPlaying.viewportInnerSpacing
            + (EnsembleScaffold.NowPlaying.viewportMinimumPanelWidth * 2)
        return size.width >= minimumWideWidth
            && size.width > size.height * EnsembleScaffold.NowPlaying.viewportWideAspectMultiplier
    }

    private func handleDismiss() {
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }
}
