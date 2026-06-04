import SwiftUI

/// Lightweight width measurement for persistent list/detail surfaces.
///
/// Keep callers responsible for guarding state writes, because each surface owns
/// its own tolerance and derived layout state.
public struct MeasuredWidthReader: View {
    private let onChange: (CGFloat) -> Void

    public init(onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
    }

    public var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear {
                    onChange(geometry.size.width)
                }
                .onChange(of: geometry.size.width) { newWidth in
                    onChange(newWidth)
                }
        }
    }
}

public extension View {
    /// Measures the rendered width of this view without forcing each screen to
    /// duplicate a background `GeometryReader`.
    func measuredWidth(onChange: @escaping (CGFloat) -> Void) -> some View {
        background(MeasuredWidthReader(onChange: onChange))
    }
}
