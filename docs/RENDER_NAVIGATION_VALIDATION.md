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

## Effects scroll position (2026-10-15)

The reported symptom is an intermittently black Effects screen after returning
from Now Playing, with controls reappearing when scrolled toward the top. The
previous screen retained its offset, used a lazy outer stack containing one
very tall controls stack, and added 132 pt of bottom padding despite the root
reserving the custom tab bar through a safe-area inset. These are concrete
layout risks; the report alone does not prove which caused the intermittent
blank frame on the affected device.

The bounded Effects content now uses a regular VStack so its actual height is
available when restoring layout. A ScrollViewReader targets a stable header
when the tab is presented and the deferred controls are ready. Its cancellable
task yields before scrolling without animation. Control identity remains
stable, and telemetry/model publications do not change the task's identity.
Bottom padding is now 16 pt in addition to the existing vertical padding and
root safe-area reservation. No audio-engine or effect-setting logic changed.

Validation used an isolated copy of the production views on iOS 26.2 simulators
for iPhone SE (3rd generation) and iPhone 16 Pro Max. External service startup
was disabled and mode state was injected without running the audio engine.
The host drove the root's actual tab state and set/read UIKit scroll offsets;
these were programmatic interactions, not physical touch tests.

| Scenario | SE | 16 Pro Max |
| --- | ---: | ---: |
| Leave during the initial 550 ms preparation, then re-enter | Pass | Pass |
| Scroll Pro to the bottom | 4,905 pt | 4,640.67 pt |
| Publish playback time while at the bottom | Offset unchanged | Offset unchanged |
| Now Playing → Effects after scrolling to the bottom | 10 pt | 10 pt |
| Scroll down, leave, shrink Pro → OFF, then return | 0 pt | 0 pt |
| Display Basic after OFF | 0 pt | 0 pt |

Offsets include the adjusted top inset; 10 pt aligns the header after its
normal top padding. Final Basic screenshots showed the header, mode selector
and effect controls on both sizes. The iOS app and simulator preview builds
passed, as did `git diff --check`. The disposable host and screenshots live
outside the application source and are not shipped.

⭕️ [Pending] On the affected iPhone, repeat tab switches during playback from
Pro's bottom, OFF and Basic; include rapid switches before first preparation
finishes and background/foreground return. Confirm controls remain visible,
normal scrolling does not snap back during playback, and there is no audible
interruption. The simulator checks do not reproduce the original intermittent
device-specific blank screen or validate live audio/gesture performance.

## Artwork swipe album entrance (2026-10-15)

The artwork's upward gesture now has a separate callback from the accessibility
album action. Only that gesture stages the Library NavigationStack off the left
edge, prepares the existing artist/album path without a forward push, and
animates the stack to zero horizontal offset in 300 ms. The width comes from
its actual container. The custom tab bar remains outside that transform.
Normal library pushes/pops and the accessibility action keep their existing
navigation. Reduce Motion skips the custom horizontal entrance. Leaving the
Library tab clears both the pending request and the entrance offset.

Validation:

- The iOS build and `run_navigation_presentation_regression.sh` passed.
- An isolated production-view host on iOS 26.2, SE (3rd generation) and
  16 Pro Max, invoked the same root handler used by the swipe. Initial entry,
  artist back-path restoration, repeated entry, cancellation by another tab,
  and the standard non-swipe action all passed.
- Frame inspection of an SE simulator recording confirmed the incoming album
  content moving from left to right while the bottom tab bar stayed fixed.
  Final screenshots on both sizes showed the album header and song rows
  within the screen.

The disposable host used fixed album/song data with external service startup
and artwork queries disabled. These checks exercised the presentation handler
and rendered transition, not a physical swipe or live audio playback. Confirm
gesture feel on the affected iPhone; no audio processing code changed.

## Now Playing DSP readiness (2026-10-15)

Paused startup restoration selects a track before asynchronous local
preparation completes, without setting the autoplay-specific loading flags.
Consequently `hasTrack` could become true and hide the initial spinner while
PCM/format/DSP preparation was still pending. The local preparation task now
publishes its lifetime into `isLoading`; success, failure, transition and stop
already clear that task. The signal summary is withheld during preparation
and no longer initializes the engine just to read the badge.

Now Playing uses the shared loading state for the artwork spinner and all
transport/mode buttons. Seek ignores changes and hit testing while loading;
horizontal artwork track-changing gestures also reject actions. Album
navigation remains available. A stale cache error cannot clear a newer
preparation task. System playback is not gated on a DSP badge, which its
protected playback path does not provide.

Validation on iOS 26.2 SE (3rd generation) and 16 Pro Max simulators used an
isolated production-view/model copy with external startup services disabled.
A generated stereo 44.1 kHz WAV ran through the shipping local load method and
engine with autoplay disabled. A three-second delay was inserted at the cache
boundary solely to make the pending state observable.

- Both devices: while selected but not prepared, `isLoading` was true, autoplay
  flags were false, and the DSP summary was nil. At completion, the spinner
  cleared, the 96 kHz / 24-bit / DSP badge appeared, and playback controls
  became active while playback remained paused. Screenshots were inspected.
- Missing file: failure cleared loading and published an error.
- Cancel and replace: cancellation cleared loading; the replacement remained
  loading until its own successful completion and then exposed the DSP badge.
- Injected system-playback state: absent DSP summary did not leave loading
  active or initialize the local engine. This is not a DRM service test.
- iOS build, `run_playback_transport_regression.sh` and `git diff --check`
  passed. The existing transport suite also covers protected startup error,
  timeout and superseded-request policies.

⭕️ [Pending] Confirm real-device startup restoration, slow remote files and
protected Music playback, including physical button/seek gestures. Simulator
screenshots and state checks do not establish live remote-service behavior.
