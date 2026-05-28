import EnsembleCore
import Foundation
import SwiftUI

@MainActor
extension NavigationCoordinator {
    /// Builds a route-owned navigation control that uses native typed links where
    /// available and coordinator pushes for legacy root stacks.
    @ViewBuilder
    func routeLink<Label: View>(
        to destination: Destination,
        in tab: TabItem? = nil,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            NavigationLink(value: destination) {
                label()
            }
            .simultaneousGesture(TapGesture().onEnded(markRouteInteraction))
        } else {
            Button {
                self.pushFromRouteLink(destination, in: tab)
            } label: {
                label()
            }
        }
    }

    /// Routes actions chosen from menus after the native menu has time to dismiss.
    func routeFromMenu(to destination: Destination, in tab: TabItem? = nil) {
        markRouteInteraction()
        let targetTab = tab ?? selectedTab
        scheduleAfterMenuDismissal { [weak self] in
            withAnimation(.default) {
                self?.push(destination, in: targetTab)
            }
        }
    }

    /// Routes cross-surface menu actions using the coordinator's active-tab fallback.
    func navigateFromMenu(to destination: Destination) {
        markRouteInteraction()
        scheduleAfterMenuDismissal { [weak self] in
            withAnimation(.default) {
                self?.navigate(to: destination)
            }
        }
    }
}

private extension NavigationCoordinator {
    func pushFromRouteLink(_ destination: Destination, in tab: TabItem?) {
        let targetTab = tab ?? selectedTab
        beginRouteTransition(in: targetTab)
        markRouteInteraction()
        push(destination, in: targetTab)
    }

    func scheduleAfterMenuDismissal(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
            Task { @MainActor in
                action()
            }
        }
    }

    func markRouteInteraction() {
        let scheduler = DependencyContainer.shared.foregroundWorkScheduler
        scheduler.beginInteraction(.navigating)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            scheduler.endInteraction(.navigating)
        }
    }
}
