# Watch UI

- Watch is a lightweight standalone Plex client plus optional iPhone remote. It
  must not import `EnsembleCore` or `EnsembleUI`; downloads remain outside its
  current standalone scope.
- Keep navigation shallow: Pins and library categories lead to native detail
  lists, with persistent top-trailing access to Now Playing.
- Watch Albums use the existing fixed two-cover Crown experience. Slow detents
  move one album; fast input moves among alphabetical section starts. The system
  owns Crown detents, haptics, accessory appearance, and transient visibility.
  Do not add a ScrollView, page indicator, drag recognizer, or manual offset
  tracker to the album cards.
- Album and playlist details use the native vertical-page `TabView`: fixed hero
  page followed by the native track list. Keep requests scoped/cancellable so an
  older destination cannot replace the active detail.
- Every Play, Shuffle, or track tap starts its scoped queue and presents the
  single root-owned Now Playing sheet. Native toolbars own close, transport, and
  More actions; `WKInterfaceVolumeControl` owns Crown volume.
- Route controls to exactly one active owner: Watch-local playback or iPhone
  remote. Phone Apple Music is metadata/transport remote control only; do not
  sync its source catalog to Watch.
- Render persisted catalog content immediately during discovery and refresh.
  Recoverable failures must not replace usable cached UI.
