import SwiftUI

public struct ScrollIndex: View {
    let letters: [String]
    @Binding var currentLetter: String?
    let onLetterTap: (String) -> Void
    
    @State private var dragLetter: String?
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 4
    
    public init(letters: [String], currentLetter: Binding<String?>, onLetterTap: @escaping (String) -> Void) {
        self.letters = letters
        self._currentLetter = currentLetter
        self.onLetterTap = onLetterTap
    }
    
    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 2) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                        .frame(width: 20, height: 15)
                        .contentShape(Rectangle())
                }
            }
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let index = letterIndex(for: value.location.y, totalHeight: geometry.size.height),
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
        }
        .padding(.trailing, 2)
    }

    /// Maps drag y-position to the nearest index slot using the rendered control
    /// height instead of hardcoded letter dimensions.
    private func letterIndex(for locationY: CGFloat, totalHeight: CGFloat) -> Int? {
        guard !letters.isEmpty else { return nil }

        let topInset = verticalPadding
        let bottomInset = verticalPadding
        let usableHeight = totalHeight - topInset - bottomInset
        guard usableHeight > 0 else { return 0 }

        let clampedY = min(max(locationY - topInset, 0), max(usableHeight - 0.001, 0))
        let normalized = clampedY / usableHeight
        let rawIndex = Int(normalized * CGFloat(letters.count))
        return min(max(rawIndex, 0), letters.count - 1)
    }
}
