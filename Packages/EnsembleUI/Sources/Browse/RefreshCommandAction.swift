import SwiftUI

/// Focused refresh action exposed by screens that already support pull-to-refresh.
public struct RefreshCommandAction {
    public let title: String
    public let perform: @MainActor () async -> Void

    public init(title: String = "Refresh", perform: @escaping @MainActor () async -> Void) {
        self.title = title
        self.perform = perform
    }
}

private struct RefreshCommandActionKey: FocusedValueKey {
    typealias Value = RefreshCommandAction
}

public extension FocusedValues {
    var ensembleRefreshAction: RefreshCommandAction? {
        get { self[RefreshCommandActionKey.self] }
        set { self[RefreshCommandActionKey.self] = newValue }
    }
}

public extension View {
    func refreshCommand(
        _ title: String = "Refresh",
        perform: @escaping @MainActor () async -> Void
    ) -> some View {
        focusedSceneValue(\.ensembleRefreshAction, RefreshCommandAction(title: title, perform: perform))
    }
}
