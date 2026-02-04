import SwiftUI

public struct ScrollIndex: View {
    let letters: [String]
    @Binding var currentLetter: String?
    let onLetterTap: (String) -> Void
    
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
                    .onTapGesture {
                        onLetterTap(letter)
                    }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .padding(.trailing, 2)
    }
}
