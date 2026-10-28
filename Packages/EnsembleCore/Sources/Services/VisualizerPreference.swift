import Foundation

/// Classic full-screen Now Playing visualizer styles.
public enum VisualizerStyle: String, CaseIterable, Identifiable, Sendable {
    case battery
    case bars
    case waves

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .battery: return "Battery"
        case .bars: return "Bars"
        case .waves: return "Waves"
        }
    }

    public var subtitle: String {
        switch self {
        case .battery: return "Swirling color trails that pulse with the beat"
        case .bars: return "Spectrum bars with falling peaks"
        case .waves: return "A glowing waveform that drifts like mist"
        }
    }
}

public enum VisualizerPreference {
    public static let enabledKey = "nowPlayingVisualizerEnabled"
    public static let styleKey = "nowPlayingVisualizerStyle"
    public static let defaultStyle = VisualizerStyle.battery
}
