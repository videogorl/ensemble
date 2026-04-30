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
    enum ActionRole {
        case primary
        case secondary

        var backgroundColor: Color {
            switch self {
            case .primary:
                return EnsembleDesign.Color.accent
            case .secondary:
                return EnsembleDesign.Color.secondaryControlFill
            }
        }

        var foregroundColor: Color {
            switch self {
            case .primary:
                return EnsembleDesign.Color.onAccent
            case .secondary:
                return EnsembleDesign.Color.primaryText
            }
        }
    }

    /// Shared Play/Shuffle-style label used by media detail action rows.
    struct ActionLabel: View {
        let title: String
        let systemImage: String
        let role: ActionRole
        let font: Font
        let verticalPadding: CGFloat
        let cornerRadius: CGFloat

        init(
            _ title: String,
            systemImage: String,
            role: ActionRole,
            font: Font = EnsembleDesign.Typography.actionLabel,
            verticalPadding: CGFloat = EnsembleScaffold.DetailSurface.actionVerticalPadding,
            cornerRadius: CGFloat = EnsembleScaffold.DetailSurface.actionCornerRadius
        ) {
            self.title = title
            self.systemImage = systemImage
            self.role = role
            self.font = font
            self.verticalPadding = verticalPadding
            self.cornerRadius = cornerRadius
        }

        var body: some View {
            HStack {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(font)
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .background(role.backgroundColor)
            .foregroundColor(role.foregroundColor)
            .cornerRadius(cornerRadius)
        }
    }

    /// Shared horizontal container for Play/Shuffle-style detail actions.
    struct ActionRow<RowContent: View>: View {
        let horizontalPadding: CGFloat
        let bottomPadding: CGFloat
        let isDisabled: Bool
        @ViewBuilder private let content: () -> RowContent

        init(
            horizontalPadding: CGFloat = 0,
            bottomPadding: CGFloat = 0,
            isDisabled: Bool = false,
            @ViewBuilder content: @escaping () -> RowContent
        ) {
            self.horizontalPadding = horizontalPadding
            self.bottomPadding = bottomPadding
            self.isDisabled = isDisabled
            self.content = content
        }

        var body: some View {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                content()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, bottomPadding)
            .chromelessMediaControlButton()
            .disabled(isDisabled)
        }
    }

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
            wideLayoutThreshold: CGFloat = EnsembleScaffold.DetailSurface.wideHeaderThreshold,
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
                VStack(spacing: EnsembleScaffold.DetailSurface.compactHeaderSpacing) {
                    artwork()
                    metadata(.center)
                }
                .padding(EnsembleScaffold.DetailSurface.headerPadding)

                compactActions()
            }
        }

        private var wideHeader: some View {
            HStack(alignment: .center, spacing: EnsembleScaffold.DetailSurface.wideHeaderSpacing) {
                artwork()

                VStack(alignment: .leading, spacing: EnsembleScaffold.DetailSurface.metadataSpacing) {
                    metadata(.leading)
                    wideActions(actionColumnWidth > 0 ? actionColumnWidth : containerWidth)
                        .padding(.top, EnsembleScaffold.DetailSurface.actionTopPadding)
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
            .padding(EnsembleScaffold.DetailSurface.headerPadding)
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
                .cornerRadius(EnsembleScaffold.DetailSurface.listCardCornerRadius)
                .padding(.horizontal, EnsembleScaffold.DetailSurface.listCardHorizontalPadding)
        }

        private var cardBackground: Color {
            EnsembleScaffold.DetailSurface.listCardBackground
        }
    }
}

extension View {
    func mediaDetailArtworkShadow() -> some View {
        shadow(
            color: EnsembleScaffold.DetailSurface.ArtworkShadow.color,
            radius: EnsembleScaffold.DetailSurface.ArtworkShadow.radius,
            x: EnsembleScaffold.DetailSurface.ArtworkShadow.x,
            y: EnsembleScaffold.DetailSurface.ArtworkShadow.y
        )
    }
}
