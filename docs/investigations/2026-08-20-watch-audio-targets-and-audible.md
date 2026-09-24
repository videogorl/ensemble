# Apple Watch audio targets and Audible comparison

Date: 2026-08-20  
Status: research only

## Conclusion

The public API closest to Apple Music's Watch experience is WatchKit's
[`NowPlayingView`](https://developer.apple.com/documentation/watchkit/nowplayingview),
available on watchOS 7 and later. It embeds the system-owned Now Playing
surface and automatically chooses the current or most recently used audio
source on the Watch or paired iPhone.

It is not a programmable AirPlay or device-target API. Apple does not expose
the exact Apple Music “Control Other Devices” browser, its destination list, or
an API that lets an app select the paired iPhone/Watch on the user's behalf.
`NowPlayingView` also occupies the whole screen and provides no customization
or programmatic access to its contents.

## Public API boundary

| Need | Public API | Boundary |
| --- | --- | --- |
| System Now Playing controls | `WatchKit.NowPlayingView` | Controls the system's current/recent source; source selection is automatic and system-owned. |
| Auto-launch a Watch companion when the iPhone starts audio | `PUICAutoLaunchAudioOptOut = false` and `handleRemoteNowPlayingActivity()` | Supports a corresponding iPhone app's Now Playing experience, not arbitrary device discovery. |
| Change Watch or iPhone volume | `WKInterfaceVolumeControl(.local)` / `.companion` | System volume only; no transport or destination switching. |
| Choose AirPlay destinations | `AVRoutePickerView` | Public on iOS, iPadOS, macOS, tvOS, and visionOS; unavailable in the watchOS SDK. `MPVolumeView` is also unavailable on watchOS. |
| Start Watch long-form audio on an eligible output | `AVAudioSession` with `.longFormAudio` and `activate(options:completionHandler:)` | The watchOS system may present a route picker, but this is the long-form/Bluetooth audio path, not the Apple Music peer-device browser. |
| App-defined Watch/iPhone ownership | `WatchConnectivity` | The correct public mechanism for an explicit, deterministic Ensemble target switch. `sendMessage` requires reachability; application context is appropriate for latest state. |

Apple's user documentation confirms that the built-in Now Playing app can
control media on the Watch, iPhone, and other devices, and that its AirPlay
controls can add or stop destinations:
[`Use Now Playing on Apple Watch`](https://support.apple.com/en-asia/guide/watch/apd4ea5db227/watchos).
That documents system behavior, not a public API for reproducing the same
destination browser.

## What this means for Ensemble

Ensemble already has the app-owned pieces: standalone Watch playback, long-form
audio, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, a
`WatchConnectivity` command/state bridge, and local/companion
`WKInterfaceVolumeControl`. The Watch app also currently keeps
`PUICAutoLaunchAudioOptOut` set to false.

The smallest useful experiment is therefore a separate full-screen Watch
surface using `NowPlayingView`, without replacing the existing player or
WatchConnectivity target menu. That will determine what the system exposes for
Ensemble's Watch-local and iPhone playback. Keep the existing explicit target
switch because `NowPlayingView` cannot be driven programmatically.

MusicKit is not the missing layer: the public `ApplicationMusicPlayer` and
`SystemMusicPlayer` APIs are not available on watchOS. Apple Music's behavior
should not be treated as evidence that a public MusicKit route-control API
exists.

## Audible comparison

Audible's public documentation describes a standalone Watch player rather than
a documented cross-device route controller:

- Audible supports downloading or streaming titles directly on the Watch,
  including phone-free playback through paired Bluetooth headphones or
  speakers: [`Listen with Apple Watch`](https://help.audible.com/s/article/listen-with-apple-watch?language=en_US)
  and [`Stream and Download Titles with Just One Tap`](https://www.audible.com/about/newsroom/stream-and-download-titles-with-just-one-tap-on-the-apple-watch).
- Audible says the Watch app can control playback and manage its library, and
  its position sync lets playback continue on another device. Its current
  public help/store material does not document an API or implementation for
  Apple Music-style “Control Other Devices” routing.
- Apple’s own Audiobooks app explicitly documents a More > AirPlay flow that
  can choose the paired iPhone, Bluetooth devices, or the Watch speaker:
  [`Play audiobooks on Apple Watch`](https://support.apple.com/en-ie/guide/watch/apd052dcfb29/watchos).

If the current Audible Watch build visibly shows the same destination UI, the
public evidence cannot identify whether it is using `NowPlayingView`, another
system-owned service, or private Audible/Apple entitlements. The observable
product model is still consistent with a Watch-local player plus synchronized
position, not a reusable public route framework.

## Verification boundary

The exact presence of the Apple Music-style More > AirPlay and “Control Other
Devices” actions for a third-party `NowPlayingView` needs a physical paired
Watch test. Simulator/UI inspection cannot establish AirPlay, locked-device,
background, or system Now Playing behavior.

The relevant Apple references are:

- [`Adding a Now Playing View`](https://developer.apple.com/documentation/watchkit/adding-a-now-playing-view)
- [`PUICAutoLaunchAudioOptOut`](https://developer.apple.com/documentation/bundleresources/information-property-list/puicautolaunchaudiooptout)
- [`handleRemoteNowPlayingActivity`](https://developer.apple.com/documentation/watchkit/wkapplicationdelegate/handleremotenowplayingactivity)
- [`WKInterfaceVolumeControl`](https://developer.apple.com/documentation/watchkit/wkinterfacevolumecontrol)
- [`AVRoutePickerView`](https://developer.apple.com/documentation/avkit/avroutepickerview)
- [`AVAudioSession.RouteSharingPolicy.longFormAudio`](https://developer.apple.com/documentation/avfaudio/avaudiosession/routesharingpolicy-swift.enum/longformaudio)
- [`WatchConnectivity`](https://developer.apple.com/documentation/watchconnectivity)
