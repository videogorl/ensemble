import EnsembleCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

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

                #if os(macOS)
                WindowToolbarVisibilityBridge(isToolbarVisible: false)
                    .allowsHitTesting(false)
                #endif

                topToolbarItemMask(for: geometry)
                
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

    @ViewBuilder
    private func topToolbarItemMask(for geometry: GeometryProxy) -> some View {
        #if os(macOS)
        EmptyView()
        #else
        if shouldUseSideBySideLayout(geometry: geometry) {
            let lightOverlayColor: Color = {
                return Color(uiColor: .systemBackground)
            }()

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: viewportLeadingTrafficLightClearance)

                Rectangle()
                    .fill(colorScheme == .dark ? Color.black.opacity(0.35) : lightOverlayColor.opacity(0.82))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: viewportToolbarMaskHeight(for: geometry))
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(true)
            .ignoresSafeArea(edges: .top)
        }
        #endif
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
            viewportHeader(for: geometry)

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

    private func viewportHeader(for geometry: GeometryProxy) -> some View {
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
                if viewModel.lyricsState.isAvailable {
                    Text("Lyrics").tag(2)
                }
                Text("Info").tag(3)
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
        .padding(.leading, viewportLeadingSystemChromeInset(for: geometry))
        .padding(.trailing, 8)
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
        if #available(iOS 26.0, *) {
            // iPadOS 26 places desktop-style window controls in the top-left
            // corner, so keep the header content below that control group.
            return max(geometry.safeAreaInsets.top + 18, 30)
        }
        return max(geometry.safeAreaInsets.top + 12, 20)
        #endif
    }

    private func viewportLeadingSystemChromeInset(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        // Reserve the traffic-light cluster plus a little breathing room so
        // Now Playing content never competes with the window controls.
        return max(geometry.safeAreaInsets.leading + viewportLeadingTrafficLightClearance, viewportLeadingTrafficLightClearance)
        #else
        if #available(iOS 26.0, *) {
            // iPadOS 26 adopts top-left window controls for multiwindow apps.
            // Mirror the macOS clearance so the header stays visually centered
            // while leaving the control cluster unobstructed.
            return max(geometry.safeAreaInsets.leading + viewportLeadingTrafficLightClearance, viewportLeadingTrafficLightClearance)
        }
        return 8
        #endif
    }

    private var viewportLeadingTrafficLightClearance: CGFloat {
        #if os(macOS)
        return 88
        #else
        if #available(iOS 26.0, *) {
            return 92
        }
        return 8
        #endif
    }

    private func viewportToolbarMaskHeight(for geometry: GeometryProxy) -> CGFloat {
        #if os(macOS)
        return max(geometry.safeAreaInsets.top + 20, 58)
        #else
        if #available(iOS 26.0, *) {
            return max(geometry.safeAreaInsets.top + 18, 54)
        }
        return 0
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

#if os(macOS)
/// Keeps the macOS titlebar visible while hiding the active window's toolbar items.
private struct WindowToolbarVisibilityBridge: NSViewRepresentable {
    let isToolbarVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.apply(to: nsView.window, isToolbarVisible: isToolbarVisible)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var originalToolbarVisibility: Bool?

        func apply(to window: NSWindow?, isToolbarVisible: Bool) {
            guard let window else { return }

            if self.window !== window {
                restore()
                self.window = window
                originalToolbarVisibility = window.toolbar?.isVisible ?? true
            }

            guard window.toolbar?.isVisible != isToolbarVisible else { return }
            window.toolbar?.isVisible = isToolbarVisible
        }

        func restore() {
            guard let window, let originalToolbarVisibility else { return }
            window.toolbar?.isVisible = originalToolbarVisibility
        }
    }
}
#endif
