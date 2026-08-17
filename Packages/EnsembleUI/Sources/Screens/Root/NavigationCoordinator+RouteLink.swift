import EnsembleCore
import Foundation
import SwiftUI

@MainActor
extension NavigationCoordinator {
    /// Builds a route-owned navigation control that pushes through the scene-local
    /// coordinator path.
    @ViewBuilder
    func routeLink<Label: View>(
        to destination: Destination,
        in tab: TabItem? = nil,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            self.route(to: destination, in: tab)
        } label: {
            label()
        }
    }

    /// Routes a direct user selection through the same transition bookkeeping as a route link.
    func route(to destination: Destination, in tab: TabItem? = nil) {
        let targetTab = tab ?? selectedTab
        beginRouteTransition(in: targetTab)
        markRouteInteraction()
        push(destination, in: targetTab)
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
