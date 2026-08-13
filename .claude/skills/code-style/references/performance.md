# Swift Performance Reference

Load this reference only for performance-sensitive Swift or SwiftUI work.

- Persistent views should observe focused publishers or local projections, not
  broad high-frequency singleton objects. Guard assignments so unchanged values
  do not publish.
- Keep per-frame waveform, FFT, Canvas, TimelineView, and Metal buffers outside
  `@State`, `@Published`, and broad `ObservableObject` invalidation. Let the
  renderer read a stable non-publishing snapshot.
- Cache O(n) or sorting projections outside `body`; precompute sort keys and use
  deterministic tie-breakers. Prefer existing filtering/sorting engines.
- Never use `UserDefaults.didChangeNotification` as a specific-key publisher.
  Compare the relevant value or use a focused owner.
- Batch file and database work. Prefetch relationships that mapping will read,
  use background CoreData contexts, and avoid per-item filesystem queries.
- Decode/downsample artwork to the displayed size and use Nuke plus the durable
  artwork cache. Never apply live large-layer SwiftUI blur.
- Use `.utility` or `.background` priority for optional analysis, healing, and
  derived artifacts. User playback and requested downloads remain higher
  priority.
- Cache device capability such as processor count once; never query it in a
  render or animation loop.
- Keep lifecycle suspension distinct from a user pause so foregrounding cannot
  restart work the user stopped.
- Prefer cancellable `.task(id:)` ownership over timers, recursive asyncAfter,
  or manual token counters for view-owned asynchronous work.
- Measure before adding throttling, caching, or a custom observation layer.
  Retain a tuning knob when real hardware variation requires calibration.
