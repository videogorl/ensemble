import EnsembleDesignTokens
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct ScrollIndex: View {
    let letters: [String]
    @Binding var currentLetter: String?
    let onLetterTap: (String) -> Void

    #if os(iOS)
    @StateObject private var scrollInterrupter = ScrollIndexScrollInterrupter()
    #endif
    
    @State private var dragLetter: String?
    private let verticalPadding = EnsembleScaffold.ScrollIndex.verticalPadding
    private let letterHeight = EnsembleScaffold.ScrollIndex.letterHeight
    private let letterSpacing = EnsembleScaffold.ScrollIndex.letterSpacing
    private let hitTargetWidth = EnsembleScaffold.ScrollIndex.hitTargetWidth
    
    public init(letters: [String], currentLetter: Binding<String?>, onLetterTap: @escaping (String) -> Void) {
        self.letters = letters
        self._currentLetter = currentLetter
        self.onLetterTap = onLetterTap
    }

    public static func isVisible(forContainerWidth width: CGFloat) -> Bool {
        #if os(macOS)
        return false
        #elseif os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        return width < EnsembleDesign.Breakpoint.browseSplitMinimumWidth
        #else
        return width < EnsembleDesign.Breakpoint.browseSplitMinimumWidth
        #endif
    }
    
    public var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: letterSpacing) {
                ForEach(letters, id: \.self) { letter in
                    Button {
                        select(letter)
                        dragLetter = nil
                    } label: {
                        Text(letter)
                            .font(EnsembleScaffold.ScrollIndex.letterFont)
                            .foregroundColor(EnsembleDesign.Color.accent)
                            .frame(width: hitTargetWidth, height: letterHeight, alignment: .center)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(letter)
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.vertical, verticalPadding)

            Color.clear
                .frame(width: hitTargetWidth, height: indexHeight)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let index = letterIndex(for: value.location.y),
                                  letters.indices.contains(index) else { return }

                            select(letters[index])
                        }
                        .onEnded { _ in
                            dragLetter = nil
                        }
                )
                .accessibilityHidden(true)
        }
        .padding(.trailing, EnsembleDesign.Spacing.none)
        #if os(iOS)
        .background {
            ScrollIndexScrollProbe(interrupter: scrollInterrupter)
                .allowsHitTesting(false)
        }
        #endif
    }

    private var indexHeight: CGFloat {
        guard !letters.isEmpty else { return verticalPadding * 2 }

        return (CGFloat(letters.count) * letterHeight)
            + (CGFloat(max(letters.count - 1, 0)) * letterSpacing)
            + (verticalPadding * 2)
    }

    private func select(_ letter: String) {
        guard letter != dragLetter else { return }

        dragLetter = letter
        #if os(iOS)
        scrollInterrupter.stopDeceleration()
        #endif
        onLetterTap(letter)

        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// Maps a drag/tap y-position within the compact control to the containing letter slot.
    private func letterIndex(for locationY: CGFloat) -> Int? {
        Self.letterIndex(
            for: locationY,
            letterCount: letters.count,
            letterHeight: letterHeight,
            letterSpacing: letterSpacing,
            verticalPadding: verticalPadding
        )
    }

    static func letterIndex(
        for locationY: CGFloat,
        letterCount: Int,
        letterHeight: CGFloat,
        letterSpacing: CGFloat,
        verticalPadding: CGFloat
    ) -> Int? {
        guard letterCount > 0 else { return nil }

        let slotHeight = letterHeight + letterSpacing
        guard slotHeight > 0 else { return nil }

        let contentHeight = (CGFloat(letterCount) * letterHeight)
            + (CGFloat(max(letterCount - 1, 0)) * letterSpacing)
        let clampedY = min(
            max(locationY - verticalPadding, 0),
            max(contentHeight - 0.001, 0)
        )
        let containingSlot = Int((clampedY / slotHeight).rounded(.down))
        return min(max(containingSlot, 0), letterCount - 1)
    }
}

#if os(iOS)
@MainActor
private final class ScrollIndexScrollInterrupter: ObservableObject {
    weak var probeView: UIView?

    func stopDeceleration() {
        guard let probeView,
              let window = probeView.window else { return }

        let point = probeView.convert(
            CGPoint(x: -1, y: probeView.bounds.midY),
            to: window
        )
        var candidate = window.hitTest(point, with: nil)

        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                guard scrollView.isDecelerating, scrollView.isScrollEnabled else { return }
                scrollView.isScrollEnabled = false
                scrollView.isScrollEnabled = true
                return
            }
            candidate = view.superview
        }
    }
}

private struct ScrollIndexScrollProbe: UIViewRepresentable {
    let interrupter: ScrollIndexScrollInterrupter

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        interrupter.probeView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        interrupter.probeView = uiView
    }
}
#endif

public enum ScrollIndexPlacement {
    case bottomChrome
    case centered
}

public extension View {
    /// Places the scroll index as viewport chrome over the scroll/list owner.
    /// The caller keeps content and index layout separate so collapsing headers
    /// and scroll content do not move the index.
    @ViewBuilder
    func libraryScrollIndexOverlay<Index: View>(
        _ placement: ScrollIndexPlacement = .centered,
        @ViewBuilder index: () -> Index
    ) -> some View {
        overlay(alignment: .trailing) {
            index()
                .libraryScrollIndexPositioning(placement)
        }
    }

    /// Anchors the alphabetical scroll index in the viewport so it stays fixed
    /// between top chrome and mini-player/tab chrome while content scrolls.
    @ViewBuilder
    func libraryScrollIndexPositioning(_ placement: ScrollIndexPlacement = .centered) -> some View {
        switch placement {
        case .bottomChrome:
            bottomChromeScrollIndexPositioning()
        case .centered:
            centeredScrollIndexPositioning()
        }
    }

    /// Keeps compact browse indexes above the mini-player/tab chrome.
    @ViewBuilder
    private func bottomChromeScrollIndexPositioning() -> some View {
        #if os(iOS)
        let bottomChromeInset = TrackListLayoutMetrics.miniPlayerContainerInset
        let bottomLift = EnsembleScaffold.ScrollIndex.bottomLift
        self
            // Anchor to bottom chrome so search/filter header changes do not
            // shift the index vertically while browsing.
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomChromeInset + bottomLift)
            .padding(.trailing, EnsembleScaffold.ScrollIndex.compactTrailingPadding)
        #else
        self
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, EnsembleScaffold.ScrollIndex.regularBottomPadding)
            .padding(.trailing, EnsembleScaffold.ScrollIndex.regularTrailingPadding)
        #endif
    }

    /// Centers browse indexes beside the actual list/table content.
    @ViewBuilder
    private func centeredScrollIndexPositioning() -> some View {
        #if os(iOS)
        self
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, EnsembleScaffold.ScrollIndex.compactTrailingPadding)
        #else
        self
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, EnsembleScaffold.ScrollIndex.regularTrailingPadding)
        #endif
    }
}
