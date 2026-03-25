import EnsembleCore
import SwiftUI

/// Dedicated large-screen Now Playing presentation surface used by macOS and iPadOS.
/// This owns the viewport layout only; window chrome coordination lives outside the layout.
struct NowPlayingViewportRoot: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.colorScheme) private var colorScheme

    private let dismissAction: () -> Void

    init(
        viewModel: NowPlayingViewModel,
        dismissAction: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.dismissAction = dismissAction
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                VStack(spacing: 20) {
                    header(for: geometry)

                    HStack(spacing: 20) {
                        ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
                            .frame(maxWidth: 520, maxHeight: .infinity)

                        detailPanel
                            .frame(maxWidth: 520, maxHeight: .infinity)
                    }
                    .frame(maxWidth: 1120, maxHeight: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, topInset(for: geometry))
                .padding(.bottom, 24)
            }
        }
    }

    private var backgroundView: some View {
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

    private func header(for geometry: GeometryProxy) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.currentTrack?.title ?? "Now Playing")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                if let artist = viewModel.currentTrack?.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Picker("Panel", selection: panelSelection) {
                Text("Queue").tag(0)
                if viewModel.lyricsState.isAvailable {
                    Text("Lyrics").tag(2)
                }
                Text("Info").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: viewModel.lyricsState.isAvailable ? 300 : 220)

            Button {
                dismissAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: 1120)
        .padding(.leading, leadingSystemChromeInset(for: geometry))
        .padding(.trailing, 8)
    }

    private var panelSelection: Binding<Int> {
        Binding(
            get: {
                if viewModel.currentPage == 3 {
                    return 3
                }
                if viewModel.lyricsState.isAvailable && viewModel.currentPage == 2 {
                    return 2
                }
                return 0
            },
            set: { newValue in
                viewModel.currentPage = newValue
            }
        )
    }

    @ViewBuilder
    private var detailPanel: some View {
        if viewModel.currentPage == 3 {
            InfoCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        } else if viewModel.lyricsState.isAvailable && viewModel.currentPage == 2 {
            LyricsCard(
                viewModel: viewModel,
                currentPage: $viewModel.currentPage,
                isLowPowerMode: powerStateMonitor.isLowPowerMode
            )
        } else {
            QueueCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
        }
    }

    private func topInset(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        return max(geometry.safeAreaInsets.top + 16, 60)
        #else
        if #available(iOS 26.0, *) {
            return max(geometry.safeAreaInsets.top + 18, 30)
        }
        return max(geometry.safeAreaInsets.top + 12, 20)
        #endif
    }

    private func leadingSystemChromeInset(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        return max(geometry.safeAreaInsets.leading + trafficLightClearance, trafficLightClearance)
        #else
        if #available(iOS 26.0, *) {
            return max(geometry.safeAreaInsets.leading + trafficLightClearance, trafficLightClearance)
        }
        return 8
        #endif
    }

    private var trafficLightClearance: CGFloat {
        #if os(macOS)
        return 88
        #else
        if #available(iOS 26.0, *) {
            return 92
        }
        return 8
        #endif
    }
}
