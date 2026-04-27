import SwiftUI

/// Shared adaptive UI patterns that sit above raw design tokens.
public enum EnsembleScaffold {
    public enum FilterPresentation {
        public enum Style: Equatable {
            case toolbarPopover
            case sheet
            case inline
        }

        #if os(iOS)
        /// Default filter presentation policy for iOS and iPadOS library browse screens.
        public static func preferredStyle(horizontalSizeClass: UserInterfaceSizeClass?) -> Style {
            if #available(iOS 26.0, *), horizontalSizeClass == .regular {
                return .toolbarPopover
            }
            return .sheet
        }
        #else
        /// Default filter presentation policy for macOS library browse screens.
        public static func preferredStyle() -> Style {
            .toolbarPopover
        }
        #endif
    }
}

/// Consistent empty/loading/error state used by browse and utility screens.
public struct EnsembleStateScaffold<Action: View>: View {
    public enum Kind {
        case empty
        case loading
        case error

        var defaultIcon: String {
            switch self {
            case .empty: return EnsembleDesign.Icon.musicNote
            case .loading: return EnsembleDesign.Icon.musicNote
            case .error: return EnsembleDesign.Icon.error
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String?
    let iconSystemName: String?
    @ViewBuilder let action: () -> Action

    public init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.iconSystemName = iconSystemName
        self.action = action
    }

    public var body: some View {
        VStack(spacing: EnsembleDesign.Spacing.lg) {
            if kind == .loading {
                ProgressView()
            } else {
                Image(systemName: iconSystemName ?? kind.defaultIcon)
                    .font(EnsembleDesign.Typography.emptyStateIcon)
                    .foregroundColor(EnsembleDesign.Color.placeholderText)
            }

            VStack(spacing: EnsembleDesign.Spacing.sm) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }

            action()
        }
        .padding(.horizontal, EnsembleDesign.Spacing.xxl)
        .padding(.vertical, EnsembleDesign.Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension EnsembleStateScaffold where Action == EmptyView {
    init(
        kind: Kind,
        title: String,
        message: String? = nil,
        iconSystemName: String? = nil
    ) {
        self.init(kind: kind, title: title, message: message, iconSystemName: iconSystemName) {
            EmptyView()
        }
    }
}
