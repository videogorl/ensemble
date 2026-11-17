// Records one app's audio output to a CAF file through a Core Audio process tap.
// Usage (inside the app bundle built by build.sh):
//   open -W -n AutoMixTap.app --args <bundle-id> <seconds> <output.caf> [mute|listen]
// The tapped app is muted at the speakers while recording unless "listen" is given.
import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String, _ status: OSStatus = 0) -> Never {
    FileHandle.standardError.write("automix-tap: \(message) (\(status))\n".data(using: .utf8)!)
    let log = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] + ".error" : "/dev/null"
    try? "\(message) (\(status))\n".write(toFile: log, atomically: true, encoding: .utf8)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[2]) else { fail("usage: bundle-id seconds output.caf [mute|listen]") }
let bundleID = args[1]
let outputURL = URL(fileURLWithPath: args[3])
let mute = !(args.count > 4 && args[4] == "listen")

func processObjects(bundleID: String) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
    return objects.filter { object in
        var bundleAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var valueSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &valueSize, $0)
        }
        return status == noErr && (value as String) == bundleID
    }
}

let objects = processObjects(bundleID: bundleID)
guard !objects.isEmpty else { fail("no audio process for \(bundleID); is it running?") }

let description = CATapDescription(stereoMixdownOfProcesses: objects)
description.name = "AutoMixTap"
description.isPrivate = true
description.muteBehavior = mute ? .mutedWhenTapped : .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(description, &tapID)
guard status == noErr else { fail("could not create tap; check System Audio Recording permission", status) }

var formatAddress = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var streamFormat = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &streamFormat)
guard status == noErr, let format = AVAudioFormat(streamDescription: &streamFormat) else { fail("no tap format", status) }

let aggregate: [String: Any] = [
    kAudioAggregateDeviceNameKey: "AutoMixTap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
]
var deviceID = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
guard status == noErr else { fail("could not create aggregate device", status) }

let file: AVAudioFile
do {
    file = try AVAudioFile(
        forWriting: outputURL,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ],
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
} catch { fail("could not open output: \(error.localizedDescription)") }

let writeQueue = DispatchQueue(label: "automix-tap.write")
var ioProcID: AudioDeviceIOProcID?
status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, writeQueue) { _, inputData, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
    try? file.write(from: buffer)
}
guard status == noErr, let ioProcID else { fail("could not create IO proc", status) }
status = AudioDeviceStart(deviceID, ioProcID)
guard status == noErr else { fail("could not start capture", status) }

// A marker file tells the driver script that capture is live.
try? "\(format.sampleRate) \(format.channelCount)\n".write(toFile: outputURL.path + ".started", atomically: true, encoding: .utf8)

func stop() -> Never {
    AudioDeviceStop(deviceID, ioProcID)
    AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    AudioHardwareDestroyAggregateDevice(deviceID)
    AudioHardwareDestroyProcessTap(tapID)
    writeQueue.sync {}
    exit(0)
}

signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { stop() }
termination.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stop() }
dispatchMain()
