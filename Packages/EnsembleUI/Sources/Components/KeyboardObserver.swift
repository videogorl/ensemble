import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit

// Keyboard height publisher for iOS
extension Publishers {
    static var keyboardHeight: AnyPublisher<CGFloat, Never> {
        let willShow = NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification -> CGFloat? in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
        
        let willHide = NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .map { _ in CGFloat(0) }
        
        return Publishers.Merge(willShow, willHide)
            .eraseToAnyPublisher()
    }
}

/// Observable object to track keyboard visibility
public class KeyboardObserver: ObservableObject {
    @Published public var isVisible = false
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        Publishers.keyboardHeight
            .map { $0 > 0 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .assign(to: \.isVisible, on: self)
            .store(in: &cancellables)
    }
}

// View extension to track keyboard height
extension View {
    func keyboardAware() -> some View {
        modifier(KeyboardAwareModifier())
    }
}

struct KeyboardAwareModifier: ViewModifier {
    @State private var keyboardHeight: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardHeight)
            .onReceive(Publishers.keyboardHeight) { height in
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardHeight = height
                }
            }
    }
}
#endif
