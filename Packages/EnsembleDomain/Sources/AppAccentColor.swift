import Foundation

public enum AppAccentColor: String, CaseIterable, Identifiable {
    case purple
    case blue
    case pink
    case red
    case orange
    case yellow
    case green

    public var id: String { rawValue }
}
