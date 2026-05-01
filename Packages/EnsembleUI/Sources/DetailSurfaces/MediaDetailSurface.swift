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
        let horizontalPadding: CGFloat
        let expands: Bool

        init(
            _ title: String,
            systemImage: String,
            role: ActionRole,
            font: Font = EnsembleDesign.Typography.actionLabel,
            verticalPadding: CGFloat = EnsembleScaffold.DetailSurface.actionVerticalPadding,
            cornerRadius: CGFloat = EnsembleScaffold.DetailSurface.actionCornerRadius,
            horizontalPadding: CGFloat = EnsembleDesign.Spacing.none,
            expands: Bool = true
        ) {
            self.title = title
            self.systemImage = systemImage
            self.role = role
            self.font = font
            self.verticalPadding = verticalPadding
            self.cornerRadius = cornerRadius
            self.horizontalPadding = horizontalPadding
            self.expands = expands
        }

        var body: some View {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                    .lineLimit(1)
            }
            .font(font)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
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
            horizontalPadding: CGFloat = EnsembleDesign.Spacing.none,
            bottomPadding: CGFloat = EnsembleDesign.Spacing.none,
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

    /// Shared icon-only action used beside Play/Shuffle rows, such as Radio.
    struct IconActionLabel: View {
        let systemImage: String
        let role: ActionRole

        init(
            systemImage: String,
            role: ActionRole = .secondary
        ) {
            self.systemImage = systemImage
            self.role = role
        }

        var body: some View {
            Image(systemName: systemImage)
                .font(EnsembleDesign.Typography.actionIcon)
                .frame(
                    width: EnsembleScaffold.DetailSurface.iconActionDimension,
                    height: EnsembleScaffold.DetailSurface.iconActionDimension
                )
                .background(role.backgroundColor)
                .foregroundColor(role.foregroundColor)
                .cornerRadius(EnsembleScaffold.DetailSurface.actionCornerRadius)
        }
    }

    /// Shared Play/Shuffle action row used by media, virtual collection, and
    /// download detail headers. Extra actions allow Artist/Album radio buttons
    /// to keep the same spacing and disabled behavior without forking the row.
    struct PlaybackActionRow<ExtraActions: View>: View {
        let horizontalPadding: CGFloat
        let bottomPadding: CGFloat
        let isDisabled: Bool
        let play: () -> Void
        let shuffle: () -> Void
        @ViewBuilder private let extraActions: () -> ExtraActions

        init(
            horizontalPadding: CGFloat = EnsembleDesign.Spacing.none,
            bottomPadding: CGFloat = EnsembleDesign.Spacing.none,
            isDisabled: Bool = false,
            play: @escaping () -> Void,
            shuffle: @escaping () -> Void,
            @ViewBuilder extraActions: @escaping () -> ExtraActions
        ) {
            self.horizontalPadding = horizontalPadding
            self.bottomPadding = bottomPadding
            self.isDisabled = isDisabled
            self.play = play
            self.shuffle = shuffle
            self.extraActions = extraActions
        }

        var body: some View {
            ActionRow(
                horizontalPadding: horizontalPadding,
                bottomPadding: bottomPadding,
                isDisabled: isDisabled
            ) {
                Button(action: play) {
                    ActionLabel(
                        "Play",
                        systemImage: EnsembleDesign.Icon.play,
                        role: .primary
                    )
                }

                Button(action: shuffle) {
                    ActionLabel(
                        "Shuffle",
                        systemImage: EnsembleDesign.Icon.shuffle,
                        role: .secondary
                    )
                }

                extraActions()
            }
        }
    }

    /// Adaptive wide-header action row shared by album, artist, and virtual
    /// collection headers. The row constrains itself at narrow widths, then
    /// switches to intrinsic button sizing once the metadata column has room.
    struct AdaptivePlaybackActionRow<ExtraActions: View>: View {
        let availableWidth: CGFloat
        let isDisabled: Bool
        let includesExtraActions: Bool
        let play: () -> Void
        let shuffle: () -> Void
        @ViewBuilder private let extraActions: () -> ExtraActions

        init(
            availableWidth: CGFloat,
            isDisabled: Bool = false,
            includesExtraActions: Bool = true,
            play: @escaping () -> Void,
            shuffle: @escaping () -> Void,
            @ViewBuilder extraActions: @escaping () -> ExtraActions
        ) {
            self.availableWidth = availableWidth
            self.isDisabled = isDisabled
            self.includesExtraActions = includesExtraActions
            self.play = play
            self.shuffle = shuffle
            self.extraActions = extraActions
        }

        var body: some View {
            Group {
                if availableWidth < EnsembleScaffold.DetailSurface.compactWideActionThreshold {
                    VStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                        playButton(
                            horizontalPadding: EnsembleScaffold.DetailSurface.compactWideActionHorizontalPadding,
                            expands: true
                        )
                        shuffleButton(
                            horizontalPadding: EnsembleScaffold.DetailSurface.compactWideActionHorizontalPadding,
                            expands: true
                        )
                        extraActionRowIfNeeded
                    }
                } else if availableWidth < EnsembleScaffold.DetailSurface.stackedWideActionThreshold {
                    VStack(alignment: .leading, spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                            playButton(horizontalPadding: EnsembleScaffold.DetailSurface.compactWideActionHorizontalPadding)
                            shuffleButton(horizontalPadding: EnsembleScaffold.DetailSurface.compactWideActionHorizontalPadding)
                        }
                        extraActionRowIfNeeded
                    }
                } else {
                    HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                        playButton()
                        shuffleButton()
                        if includesExtraActions {
                            extraActions()
                        }
                    }
                }
            }
            .chromelessMediaControlButton()
            .disabled(isDisabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func playButton(
            horizontalPadding: CGFloat = EnsembleScaffold.DetailSurface.wideActionHorizontalPadding,
            expands: Bool = false
        ) -> some View {
            Button(action: play) {
                ActionLabel(
                    "Play",
                    systemImage: EnsembleDesign.Icon.play,
                    role: .primary,
                    horizontalPadding: horizontalPadding,
                    expands: expands
                )
            }
        }

        private func shuffleButton(
            horizontalPadding: CGFloat = EnsembleScaffold.DetailSurface.wideActionHorizontalPadding,
            expands: Bool = false
        ) -> some View {
            Button(action: shuffle) {
                ActionLabel(
                    "Shuffle",
                    systemImage: EnsembleDesign.Icon.shuffle,
                    role: .secondary,
                    horizontalPadding: horizontalPadding,
                    expands: expands
                )
            }
        }

        @ViewBuilder
        private var extraActionRowIfNeeded: some View {
            if includesExtraActions {
                HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                    extraActions()
                    Spacer(minLength: EnsembleDesign.Spacing.none)
                }
            }
        }
    }

    /// Compact two-button Play/Shuffle row for nested detail sections.
    struct CompactPlaybackActionRow: View {
        let horizontalPadding: CGFloat
        let bottomPadding: CGFloat
        let isDisabled: Bool
        let play: () -> Void
        let shuffle: () -> Void

        init(
            horizontalPadding: CGFloat = TrackListLayoutMetrics.rowHorizontalPadding,
            bottomPadding: CGFloat = EnsembleDesign.Spacing.none,
            isDisabled: Bool = false,
            play: @escaping () -> Void,
            shuffle: @escaping () -> Void
        ) {
            self.horizontalPadding = horizontalPadding
            self.bottomPadding = bottomPadding
            self.isDisabled = isDisabled
            self.play = play
            self.shuffle = shuffle
        }

        var body: some View {
            ActionRow(
                horizontalPadding: horizontalPadding,
                bottomPadding: bottomPadding,
                isDisabled: isDisabled
            ) {
                Button(action: play) {
                    ActionLabel(
                        "Play",
                        systemImage: EnsembleDesign.Icon.play,
                        role: .primary,
                        font: EnsembleScaffold.DetailSurface.compactActionFont,
                        verticalPadding: EnsembleScaffold.DetailSurface.compactActionVerticalPadding,
                        cornerRadius: EnsembleScaffold.DetailSurface.compactActionCornerRadius
                    )
                }

                Button(action: shuffle) {
                    ActionLabel(
                        "Shuffle",
                        systemImage: EnsembleDesign.Icon.shuffle,
                        role: .secondary,
                        font: EnsembleScaffold.DetailSurface.compactActionFont,
                        verticalPadding: EnsembleScaffold.DetailSurface.compactActionVerticalPadding,
                        cornerRadius: EnsembleScaffold.DetailSurface.compactActionCornerRadius
                    )
                }
            }
        }
    }

    struct MetadataBlock: View {
        let title: String
        let subtitle: String?
        let tertiary: String?
        let alignment: HorizontalAlignment
        let titleFont: Font

        init(
            title: String,
            subtitle: String? = nil,
            tertiary: String? = nil,
            alignment: HorizontalAlignment,
            titleFont: Font = EnsembleDesign.Typography.sectionTitle
        ) {
            self.title = title
            self.subtitle = subtitle
            self.tertiary = tertiary
            self.alignment = alignment
            self.titleFont = titleFont
        }

        var body: some View {
            VStack(alignment: alignment, spacing: EnsembleScaffold.Favorites.metadataSpacing) {
                Text(title)
                    .font(titleFont)
                    .multilineTextAlignment(textAlignment)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(EnsembleDesign.Typography.stateMessage)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(textAlignment)
                }

                if let tertiary, !tertiary.isEmpty {
                    Text(tertiary)
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(textAlignment)
                }
            }
        }

        private var textAlignment: TextAlignment {
            alignment == .center ? .center : .leading
        }
    }

    struct VirtualCollectionHeader<Artwork: View>: View {
        let title: String
        let subtitle: String?
        let tertiary: String?
        let bottomPadding: CGFloat
        @ViewBuilder private let artwork: () -> Artwork
        private let play: () -> Void
        private let shuffle: () -> Void
        private let isDisabled: Bool

        init(
            title: String,
            subtitle: String? = nil,
            tertiary: String? = nil,
            bottomPadding: CGFloat = EnsembleDesign.Spacing.none,
            isDisabled: Bool,
            @ViewBuilder artwork: @escaping () -> Artwork,
            play: @escaping () -> Void,
            shuffle: @escaping () -> Void
        ) {
            self.title = title
            self.subtitle = subtitle
            self.tertiary = tertiary
            self.bottomPadding = bottomPadding
            self.isDisabled = isDisabled
            self.artwork = artwork
            self.play = play
            self.shuffle = shuffle
        }

        var body: some View {
            Header {
                EmptyView()
            } artwork: {
                artwork()
            } metadata: { alignment in
                MetadataBlock(
                    title: title,
                    subtitle: subtitle,
                    tertiary: tertiary,
                    alignment: alignment
                )
            } compactActions: {
                PlaybackActionRow(
                    horizontalPadding: TrackListLayoutMetrics.rowHorizontalPadding,
                    bottomPadding: EnsembleDesign.Spacing.lg,
                    isDisabled: isDisabled,
                    play: play,
                    shuffle: shuffle
                ) {
                    EmptyView()
                }
            } wideActions: { availableWidth in
                AdaptivePlaybackActionRow(
                    availableWidth: availableWidth,
                    isDisabled: isDisabled,
                    includesExtraActions: false,
                    play: play,
                    shuffle: shuffle
                ) {
                    EmptyView()
                }
                .padding(.bottom, EnsembleDesign.Spacing.lg)
            }
            .padding(.bottom, bottomPadding)
        }
    }

    /// Shared symbol artwork used by virtual/detail collections without album art.
    struct SymbolArtwork: View {
        let systemImage: String
        let foregroundColor: Color
        let backgroundColor: Color
        let dimension: CGFloat
        let iconSize: CGFloat

        init(
            systemImage: String,
            foregroundColor: Color,
            backgroundColor: Color,
            dimension: CGFloat = EnsembleScaffold.Favorites.heroArtworkDimension,
            iconSize: CGFloat = EnsembleScaffold.Favorites.heroIconSize
        ) {
            self.systemImage = systemImage
            self.foregroundColor = foregroundColor
            self.backgroundColor = backgroundColor
            self.dimension = dimension
            self.iconSize = iconSize
        }

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: ArtworkCornerRadius.square(for: dimension), style: .continuous)
                    .fill(backgroundColor)

                Image(systemName: systemImage)
                    .font(.system(size: iconSize))
                    .foregroundColor(foregroundColor)
            }
            .frame(width: dimension, height: dimension)
            .mediaDetailArtworkShadow()
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
            VStack(spacing: EnsembleDesign.Spacing.none) {
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
            VStack(spacing: EnsembleDesign.Spacing.none) {
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
        ensembleArtworkShadow()
    }
}
