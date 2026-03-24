import AudioToolbox
import AVFoundation

/// Static utility that probes for AUSoundIsolation AudioComponent availability at app launch.
/// Supported on iOS 16+ / macOS 13+ devices with A13+ chip (Neural Engine required).
/// No hardcoded chip list needed -- if the AudioComponent exists on the device, it's supported.
public enum InstrumentalModeCapability {
    public static let isSupported: Bool = {
        guard #available(iOS 16.0, macOS 13.0, *) else { return false }
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x766F6973, // 'vois' — kAudioUnitSubType_AUSoundIsolation
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let found = AudioComponentFindNext(nil, &desc) != nil
        #if DEBUG
        EnsembleLogger.debug("[InstrumentalMode] AUSoundIsolation probe: \(found ? "available" : "not found")")
        #endif
        return found
    }()
}
