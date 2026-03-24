import EnsembleCore
import SwiftUI

/// Main sheet container for Now Playing interface
/// Uses native .sheet presentation with carousel layout
public struct NowPlayingSheetView: View {
    @ObservedObject var viewModel: NowPlayingViewModel
    @ObservedObject private var powerStateMonitor = DependencyContainer.shared.powerStateMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var deps
    @Environment(\.colorScheme) private var colorScheme
    
    // Page state lives on viewModel so it persists across sheet dismiss/reopen
    
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
        GeometryReader { geometry in
            ZStack {
                // Blurred artwork background with legibility overlay
                backgroundView
                
                VStack(spacing: 0) {
                    if shouldUseSideBySideLayout(geometry: geometry) {
                        viewportLayout(for: geometry)
                    } else {
                        mobileSheetLayout
                    }
                }
            }
        }
    }
    
    // MARK: - Background
    
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
            // Base blurred artwork
            BlurredArtworkBackground(
                image: viewModel.artworkImage,
                overlayColor: colorScheme == .dark ? .black : lightOverlayColor
            )
            .animation(.easeInOut(duration: 0.8), value: viewModel.artworkImage)
            
            // Legibility overlay (adapts to light/dark mode)
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
    
    // MARK: - Dismiss Pill
    
    private var dismissPill: some View {
        Capsule()
            .fill(Color.primary.opacity(0.3))
            .frame(width: 36, height: 5)
    }
    
    private var mobileSheetLayout: some View {
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

    // MARK: - iPad/Mac Viewport Layout

    private func viewportLayout(for geometry: GeometryProxy) -> some View {
        VStack(spacing: 20) {
            viewportHeader

            HStack(spacing: 20) {
                ControlsCard(viewModel: viewModel, currentPage: $viewModel.currentPage)
                    .frame(maxWidth: 520, maxHeight: .infinity)

                viewportDetailPanel
                    .frame(maxWidth: 520, maxHeight: .infinity)
            }
            .frame(maxWidth: 1120, maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, viewportTopInset(for: geometry))
        .padding(.bottom, 24)
    }

    private var viewportHeader: some View {
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

            Picker("Panel", selection: viewportPanelSelection) {
                Text("Queue").tag(0)
                Text("Info").tag(3)
                if viewModel.lyricsState.isAvailable {
                    Text("Lyrics").tag(2)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: viewModel.lyricsState.isAvailable ? 300 : 220)

            Button {
                handleDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: 1120)
        .padding(.horizontal, 8)
    }

    private var viewportPanelSelection: Binding<Int> {
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
    private var viewportDetailPanel: some View {
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
    
    private func handleDismiss() {
        if let dismissAction = dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }

    private func viewportTopInset(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        // The viewport overlay sits inside the app content area, below the
        // window toolbar. Reserve extra clearance so the header controls remain
        // tappable instead of ending up under toolbar items.
        return max(geometry.safeAreaInsets.top + 16, 60)
        #else
        return max(geometry.safeAreaInsets.top + 12, 20)
        #endif
    }
    
    private func shouldUseSideBySideLayout(geometry: GeometryProxy) -> Bool {
        // Use side-by-side when horizontal size class is regular (iPad)
        // or on macOS (always side-by-side)
        #if os(macOS)
        return true
        #else
        // iPad in landscape or split view
        return geometry.size.width > 768
        #endif
    }
}
