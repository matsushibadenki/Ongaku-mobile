# Render timing and navigation validation

## Evidence from the supplied iPhone log

The old diagnostic recorded `audio.dropout.detected gapMs=887.5`, followed by
recovery, after background/resume around external lyrics searches. The user
confirmed that external-page navigation did not audibly interrupt playback.
Transport samples continued to advance with the engine running. The log also
contained one `NavigationRequestObserver` multiple-updates-per-frame warning,
but no stack trace or navigation action identifier.

The old heartbeat measured wall-clock spacing of main-mixer **meter-tap
delivery**, not the Audio Unit's render cycles. It therefore could not
distinguish delayed tap delivery from delayed rendering. The old record cannot
prove 887.5 ms of audible silence or establish the underlying OS scheduling
cause. Background transition proximity and thermal warnings are correlations,
not proof of causation.

## Audio changes and tests

`AudioRenderHeartbeat` registers a pre-render observer on the main-mixer Audio
Unit. It counts only bus 0 pre-render events, captures the monitor rather than
the engine/UI, and removes its observer token when released. Graph/meter setup
owns that registration. The meter tap now reports its own delivery interval
separately. Both remain active when visualization calculations are suspended.

The render callback performs a best-effort nonblocking lock update, with no
logging or UI publication. Polling/logging remains outside the callback.
Skipped monitor observations, framework scheduling and output-device behavior
mean this is a diagnostic of observed render scheduling, not a loopback
measurement of audible silence. A first callback arriving after the startup
grace period now clears the stalled state; previously this recovery required
an already-observed callback and could leave the state stalled.

New logs:

- `audio.tap.delivery_gap`: delayed meter delivery, with the independent render
  gap count and observed render-callback count.
- `audio.render.gap.detected` / `audio.render.gap.recovered`: render-observer
  scheduling evidence, including source, route and enabled effects.

The effect-screen summary uses scheduling terminology in all three languages.
Unchanged render-health snapshots no longer publish every transport tick.

Run `bash tests/run_render_health_regression.sh`. The suite compiles shipping
monitor/observer sources and passed:

- A modeled 887.5 ms tap-delivery delay with continuous 10 ms render cycles:
  no render-gap count, one separate tap-delivery diagnostic.
- A render callback stopping and resuming: one detection, no duplicate poll
  event, and preserved recovery duration.
- Startup grace, recovery from an absent first callback, pause/restart and
  suppression of stale pending events.
- Real AVAudioEngine offline rendering: one pre-render observation per slice
  and no additional observations after releasing the registration.
- Non-silent stereo 997/2,303 Hz output: monitoring enabled/disabled produced
  sample-for-sample identical float PCM.

The host sandbox cannot instantiate the required Audio Units; the Audio Unit
part passed with normal host access. Offline tests do not exercise iPhone
background scheduling, Bluetooth or DAC output. The iOS app build passed.

## Navigation changes and tests

`ContentView` used to observe the entire player model while owning all
NavigationStacks and destination registration. RMS, peak, VU, spectrum and
progress publications consequently invalidated navigation ownership during
playback. The library also read large collections while rebuilding these
destinations. This was a concrete source of unnecessary navigation/UI work;
the single original warning does not prove it was the only trigger.

Navigation ownership now reads local path/tab/presentation state and only
the model's accent/error signals. Observed effect/playback content sits below
the stack owners. Library/Search use selected publisher sets and coalesce
synchronous property batches after values commit; telemetry does not forward
to these screens. Destination rows still receive relevant library, overlay,
selection, loading, permission and playback changes.

Search now registers the LibraryRoute destinations its NavigationLinks use.
Library and Search keep separate typed paths. Album navigation rejects an
identical replacement, and path/tab changes log source/depth without song
titles.

Run `bash tests/run_navigation_presentation_regression.sh`. It compiles the
shipping publisher-selection extension, coalescer, route and library models
against a controllable publisher model. All checks passed:

- 1,800 telemetry publications caused no Library/Search presentation update.
- Library/transport/overlay changes in one batch caused one update, after the
  underlying values had committed.
- Identical transport observations did not cause redundant updates.
- Query/results/catalog changes refreshed Search without refreshing Library.
- Loading, effect-processing and permission changes still refreshed controls.
- Route identity survived metadata refresh; tab paths remained independent.

This suite does not render SwiftUI or reproduce Apple's private navigation
observer. Device browsing/back gestures, lyrics sheets, rapid tab changes and
the original warning's exact trigger remain physical-device checks.

An additional isolated simulator host exercised production view copies on
iPhone SE (3rd generation) and iPhone 16 Pro Max. The copies only add initial
tab/path state and a scripted driver; the model copy disables restore/service
observers/artwork lookup and exposes initial loading state for fixture setup.
No validation hooks or fake data were added to the shipping app. Both hosts
ran 720 progress/meter writes, artist → album pushes, a metadata refresh,
Search push/pop and an album-return request. The app console and unified logs
contained no `NavigationRequestObserver` multiple-updates warning. Startup
still caused one navigation-owner body update during each telemetry phase;
the test does not claim that SwiftUI never updates navigation ownership.

The simulators initially retained a Music permission dialog from service
lookups. After isolating those calls and rebooting the test devices, the final
album screenshots showed both fixture songs, aligned information controls,
safe-area placement and readable layouts at both sizes. These scripted
screenshots do not validate physical touch/back gestures or live audio.

Artifacts from this run are under `/private/tmp`: `ongaku-render-health-tests.log`,
`ongaku-navigation-presentation-tests.log`, `ongaku-render-navigation-build.log`,
`ongaku-navigation-preview-{se,pro-max}.log`,
`ongaku-nav-{se,pro-max}-unified.log`, and
`ongaku-navigation-{se,pro-max}.png`.
