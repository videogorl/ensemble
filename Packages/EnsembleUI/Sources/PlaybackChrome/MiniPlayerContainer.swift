import EnsembleCore
import SwiftUI

public struct MiniPlayerContainer<Content: View>: View {
    let viewModel: NowPlayingViewModel
    let onMiniPlayerTap: () -> Void
    let content: () -> Content

    public init(
        viewModel: NowPlayingViewModel,
        onMiniPlayerTap: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.viewModel = viewModel
        self.onMiniPlayerTap = onMiniPlayerTap
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            content()
                .padding(.bottom, EnsembleScaffold.MiniPlayer.containerBottomPadding)

            let isFloating: Bool = {
                if #available(iOS 18.0, *) {
                    return true
                }
                return false
            }()

            MiniPlayer(
                viewModel: viewModel,
                isFloating: isFloating,
                namespace: nil, // Container doesn't support shared animation yet
                animationID: nil,
                onTap: onMiniPlayerTap
            )
        }
    }
}
