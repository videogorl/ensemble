import EnsembleCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Dedicated large-screen Now Playing presentation surface used by macOS and iPadOS.
/// This owns the viewport layout and hosts the narrow macOS toolbar suppression bridge
/// needed to keep split-view chrome out of the presentation.
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

                #if os(macOS)
                SidebarToggleToolbarSuppressionBridge()
                    .frame(width: 0, height: 0)
                #endif

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
        .onAppear {
            // Viewport layout always shows ControlsCard on the left.
            // Carousel page 1 (Controls) has no panel equivalent in this layout —
            // normalize to Queue (0) so QueueCard's isVisible check passes.
            if viewModel.currentPage == 1 {
                viewModel.currentPage = 0
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
                Text("Lyrics").tag(2)
                Text("Info").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

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
                if viewModel.currentPage == 3 { return 3 }
                if viewModel.currentPage == 2 { return 2 }
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
        } else if viewModel.currentPage == 2 {
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

#if os(macOS)
/// Hides live host toolbar items on the existing macOS window toolbar while viewport
/// Now Playing is active. This avoids mutating titlebar visibility or replacing
/// SwiftUI's managed toolbar instance.
private struct SidebarToggleToolbarSuppressionBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservationView {
        let view = WindowObservationView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowObservationView, context: Context) {
        nsView.coordinator = context.coordinator
        context.coordinator.apply(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowObservationView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var previousHiddenStates: [(item: NSToolbarItem, hidden: Bool)] = []

        func apply(to window: NSWindow?) {
            guard let window else { return }

            if self.window !== window {
                restore()
                self.window = window
            }

            guard #available(macOS 15.0, *), let toolbar = window.toolbar else { return }

            for item in toolbar.items {
                guard shouldHideToolbarItem(item) else {
                    continue
                }

                guard !previousHiddenStates.contains(where: { $0.item === item }) else {
                    continue
                }

                let previousHidden = item.isHidden
                item.isHidden = true
                previousHiddenStates.append((item, previousHidden))
            }
        }

        private func shouldHideToolbarItem(_ item: NSToolbarItem) -> Bool {
            let identifier = item.itemIdentifier

            switch identifier {
            case .flexibleSpace, .space:
                return false
            default:
                return true
            }
        }

        func restore() {
            guard #available(macOS 15.0, *) else {
                previousHiddenStates.removeAll()
                window = nil
                return
            }

            for entry in previousHiddenStates {
                entry.item.isHidden = entry.hidden
            }

            previousHiddenStates.removeAll()
            window = nil
        }
    }

    final class WindowObservationView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.apply(to: window)
            DispatchQueue.main.async { [weak self] in
                self?.coordinator?.apply(to: self?.window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.coordinator?.apply(to: self?.window)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.apply(to: window)
        }

        override func layout() {
            super.layout()
            coordinator?.apply(to: window)
        }
    }
}
#endif
