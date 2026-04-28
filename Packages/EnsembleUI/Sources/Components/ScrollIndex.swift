import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct ScrollIndex: View {
    let letters: [String]
    @Binding var currentLetter: String?
    let onLetterTap: (String) -> Void
    
    @State private var dragLetter: String?
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 4
    private let letterHeight: CGFloat = 15
    private let letterSpacing: CGFloat = 2
    
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
        VStack(spacing: letterSpacing) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
                    .frame(width: 20, height: letterHeight)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let index = letterIndex(for: value.location.y),
                          letters.indices.contains(index) else { return }

                    let letter = letters[index]
                    if letter != dragLetter {
                        dragLetter = letter
                        onLetterTap(letter)

                        #if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
                        #endif
                    }
                }
                .onEnded { _ in
                    dragLetter = nil
                }
        )
        .padding(.trailing, 0)
    }

    /// Maps a drag/tap y-position within the compact control to the nearest letter slot.
    private func letterIndex(for locationY: CGFloat) -> Int? {
        guard !letters.isEmpty else { return nil }

        let slotHeight = letterHeight + letterSpacing
        let contentHeight = (CGFloat(letters.count) * letterHeight)
            + (CGFloat(max(letters.count - 1, 0)) * letterSpacing)
        let clampedY = min(
            max(locationY - verticalPadding, 0),
            max(contentHeight - 0.001, 0)
        )
        let nearestSlot = Int((clampedY / slotHeight).rounded())
        return min(max(nearestSlot, 0), letters.count - 1)
    }
}

public enum ScrollIndexPlacement {
    case bottomChrome
    case centered
}

public extension View {
    /// Anchors the alphabetical scroll index in the viewport so it stays fixed
    /// between top chrome and mini-player/tab chrome while content scrolls.
    @ViewBuilder
    func libraryScrollIndexPositioning(_ placement: ScrollIndexPlacement = .bottomChrome) -> some View {
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
        let bottomLift: CGFloat = 6
        self
            // Anchor to bottom chrome so search/filter header changes do not
            // shift the index vertically while browsing.
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomChromeInset + bottomLift)
            .padding(.trailing, -2)
        #else
        self
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            .padding(.trailing, 2)
        #endif
    }

    /// Centers large-screen indexes beside the actual list/table content.
    @ViewBuilder
    private func centeredScrollIndexPositioning() -> some View {
        #if os(iOS)
        self
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, -2)
        #else
        self
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 2)
        #endif
    }
}
