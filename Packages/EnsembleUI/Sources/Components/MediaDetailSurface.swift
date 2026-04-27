import SwiftUI

/// Shared presentation shell for media-style detail screens.
/// The root owns the blurred artwork backdrop, while nested helpers keep the
/// header layout and list-card styling aligned across detail variants.
struct MediaDetailSurface<Content: View>: View {
    let artworkImage: UIImage?
    @ViewBuilder private let content: () -> Content

    init(
        artworkImage: UIImage?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.artworkImage = artworkImage
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .top) {
            ArtworkDetailBackground(image: artworkImage)
                .ignoresSafeArea()

            content()
        }
    }
}

extension MediaDetailSurface {
    struct Header<
        TopContent: View,
        Artwork: View,
        Metadata: View,
        CompactActions: View,
        WideActions: View
    >: View {
        @State private var containerWidth: CGFloat = 0
        @State private var actionColumnWidth: CGFloat = 0

        private let wideLayoutThreshold: CGFloat
        @ViewBuilder private let topContent: () -> TopContent
        @ViewBuilder private let artwork: () -> Artwork
        private let metadata: (HorizontalAlignment) -> Metadata
        @ViewBuilder private let compactActions: () -> CompactActions
        private let wideActions: (CGFloat) -> WideActions

        init(
            wideLayoutThreshold: CGFloat = EnsembleDesign.Breakpoint.detailWideHeader,
            @ViewBuilder topContent: @escaping () -> TopContent,
            @ViewBuilder artwork: @escaping () -> Artwork,
            metadata: @escaping (HorizontalAlignment) -> Metadata,
            @ViewBuilder compactActions: @escaping () -> CompactActions,
            wideActions: @escaping (CGFloat) -> WideActions
        ) {
            self.wideLayoutThreshold = wideLayoutThreshold
            self.topContent = topContent
            self.artwork = artwork
            self.metadata = metadata
            self.compactActions = compactActions
            self.wideActions = wideActions
        }

        var body: some View {
            VStack(spacing: 0) {
                topContent()
                adaptiveBody
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            updateContainerWidth(geometry.size.width)
                        }
                        .onChange(of: geometry.size.width) { newWidth in
                            updateContainerWidth(newWidth)
                        }
                }
            )
        }

        private var adaptiveBody: some View {
            Group {
                if containerWidth >= wideLayoutThreshold {
                    wideHeader
                } else {
                    compactHeader
                }
            }
        }

        private var compactHeader: some View {
            VStack(spacing: 0) {
                VStack(spacing: EnsembleDesign.Spacing.lg) {
                    artwork()
                    metadata(.center)
                }
                .padding()

                compactActions()
            }
        }

        private var wideHeader: some View {
            HStack(alignment: .center, spacing: EnsembleDesign.Spacing.xxl) {
                artwork()

                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.sm) {
                    metadata(.leading)
                    wideActions(actionColumnWidth > 0 ? actionColumnWidth : containerWidth)
                        .padding(.top, EnsembleDesign.Spacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                updateActionColumnWidth(geometry.size.width)
                            }
                            .onChange(of: geometry.size.width) { newWidth in
                                updateActionColumnWidth(newWidth)
                            }
                    }
                )
            }
            .padding()
        }

        private func updateContainerWidth(_ newWidth: CGFloat) {
            if abs(containerWidth - newWidth) > 1 {
                containerWidth = newWidth
            }
        }

        private func updateActionColumnWidth(_ newWidth: CGFloat) {
            if abs(actionColumnWidth - newWidth) > 1 {
                actionColumnWidth = newWidth
            }
        }
    }

    struct ListCard<CardContent: View>: View {
        @ViewBuilder private let content: () -> CardContent

        init(@ViewBuilder content: @escaping () -> CardContent) {
            self.content = content
        }

        var body: some View {
            content()
                .background(cardBackground)
                .cornerRadius(EnsembleDesign.Radius.card)
                .padding(.horizontal)
        }

        private var cardBackground: Color {
            EnsembleDesign.Color.groupedSurface
        }
    }
}
