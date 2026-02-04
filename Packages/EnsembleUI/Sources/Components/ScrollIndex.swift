import SwiftUI

public struct ScrollIndex: View {
    let letters: [String]
    @Binding var currentLetter: String?
    let onLetterTap: (String) -> Void
    
    @State private var dragLetter: String?
    
    public init(letters: [String], currentLetter: Binding<String?>, onLetterTap: @escaping (String) -> Void) {
        self.letters = letters
        self._currentLetter = currentLetter
        self.onLetterTap = onLetterTap
    }
    
    public var body: some View {
        VStack(spacing: 2) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.accentColor)
                    .frame(width: 20, height: 15)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Each letter is 15px high + 2px spacing = 17px per item
                    // Padding is 8px at top and bottom
                    let y = value.location.y - 8
                    let itemHeight: CGFloat = 17
                    let index = Int(y / itemHeight)
                    
                    if index >= 0 && index < letters.count {
                        let letter = letters[index]
                        if letter != dragLetter {
                            dragLetter = letter
                            onLetterTap(letter)
                        }
                    }
                }
                .onEnded { _ in
                    dragLetter = nil
                }
        )
        .padding(.trailing, 2)
    }
}
