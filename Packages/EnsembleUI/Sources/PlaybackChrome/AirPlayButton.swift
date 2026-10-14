import SwiftUI
import AVKit
import EnsembleCore

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Owns the card's mounted route picker. Presentation happens only after an explicit action.
@MainActor
public final class AirPlayPresentationController: ObservableObject {
    @Published public private(set) var showsFallbackButton = false
    private var presentationTask: Task<Void, Never>?

    #if canImport(UIKit) || os(macOS)
    private weak var routePicker: AVRoutePickerView?

    fileprivate func register(_ picker: AVRoutePickerView) {
        routePicker = picker
    }
    #endif

    public init() {}

    public func present() {
        presentationTask?.cancel()
        showsFallbackButton = false
        presentationTask = Task { [weak self] in
            // Native menus dismiss asynchronously; let their presentation finish first.
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self else { return }
            guard !self.triggerRoutePicker() else { return }
            EnsembleLogger.info("AirPlay route picker button unavailable; revealing native picker")
            self.showsFallbackButton = true
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            self.showsFallbackButton = false
        }
    }

    private func triggerRoutePicker() -> Bool {
        #if canImport(UIKit)
        guard let routePicker, routePicker.window != nil else { return false }
        routePicker.layoutIfNeeded()
        guard let button = findButton(in: routePicker) else { return false }
        button.sendActions(for: .touchUpInside)
        return true
        #elseif os(macOS)
        guard let routePicker, routePicker.window != nil else { return false }
        routePicker.layoutSubtreeIfNeeded()
        guard let button = findButton(in: routePicker) else { return false }
        button.performClick(nil)
        return true
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        return view.subviews.lazy.compactMap { self.findButton(in: $0) }.first
    }
    #elseif os(macOS)
    private func findButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { self.findButton(in: $0) }.first
    }
    #endif
}

#if canImport(UIKit)
/// SwiftUI wrapper for the native AirPlay button.
public struct AirPlayButton: UIViewRepresentable {
    private let presentation: AirPlayPresentationController?

    /// Pass a controller only to the card's persistent picker, not to additional visible buttons.
    public init(presentation: AirPlayPresentationController? = nil) {
        self.presentation = presentation
    }

    public func makeUIView(context: Context) -> UIView {
        let picker = AVRoutePickerView()
        updateLook(picker)
        picker.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        picker.setContentHuggingPriority(.defaultHigh, for: .vertical)
        guard let presentation else { return picker }

        // AVRoutePickerView exposes its button despite its own hidden accessibility flag.
        // A standard ancestor keeps the programmatic picker out of the accessibility tree.
        let host = UIView()
        host.addSubview(picker)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            picker.topAnchor.constraint(equalTo: host.topAnchor),
            picker.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.accessibilityElementsHidden = !presentation.showsFallbackButton
        presentation.register(picker)
        return host
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let picker = (uiView as? AVRoutePickerView) ?? uiView.subviews.first as? AVRoutePickerView else { return }
        updateLook(picker)
        if let presentation {
            uiView.accessibilityElementsHidden = !presentation.showsFallbackButton
            presentation.register(picker)
        }
    }

    private func updateLook(_ view: AVRoutePickerView) {
        view.tintColor = UIColor.label.withAlphaComponent(0.7)
        let accentColor = DependencyContainer.shared.settingsManager.accentColor.color
        view.activeTintColor = UIColor(accentColor)
    }
}
#elseif os(macOS)
public struct AirPlayButton: NSViewRepresentable {
    private let presentation: AirPlayPresentationController?

    public init(presentation: AirPlayPresentationController? = nil) {
        self.presentation = presentation
    }

    public func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        presentation?.register(picker)
        return picker
    }

    public func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        presentation?.register(nsView)
    }
}
#else
public struct AirPlayButton: View {
    public init(presentation: AirPlayPresentationController? = nil) {}
    public var body: some View { EmptyView() }
}
#endif
