# Mobile VU response / Desktop reference — 2026-10-20

## Implemented

- 🟢 [Done] Poll the mobile meter at a nominal 60 Hz (previously 30 Hz). Register the production Timer in the main run loop's common modes so tracking gestures do not suspend it. Retain the existing foreground-only start/stop lifecycle and invalidate the previous timer before replacing it.
- 🟢 [Done] Match Desktop's exponential attack/release time constants: 65 ms / 220 ms (previous mobile release: 300 ms). Use monotonic system uptime instead of wall-clock Date, respond on the first frame, and allow the same 100 ms upper timestep as Desktop. Reject non-finite time and neutralize non-finite targets. Lower the normalized publication threshold from 0.003 to 0.0005 to retain small needle changes.
- 🟢 [Done] Retain 0 VU = -18 dBFS, existing printed face/needle geometry, RMS measurement and mono/stereo presentation differences. Preserve the actual spectrum UI publication budget of 15 Hz by publishing every fourth 60 Hz tick; scale the existing synthetic-path phase increment to avoid doubling its speed.
- Audio DSP, output gain, measurement tap buffer size, FFT windows and analysis scheduling are unchanged. This is a display-response change, not a change to audible output or a claim of sample-identical Mac/iPhone meter readings. Desktop retains its existing implementation.

## Verification

- 🟢 [Done] `bash tests/run_vu_meter_response_regression.sh`: production Timer fires in AppKit's tracking run-loop mode and stops after invalidation. At 30/60/120 Hz, a 300 ms step matches the 65 ms attack and 220 ms release analytical curves; first-frame response, reset, invalid inputs, -18 dBFS alignment and the 15 Hz spectrum cadence pass.
- 🟢 [Done] Ordinary iOS Simulator Debug app build passes for arm64 and x86_64, including the project's MainActor default isolation (`xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`). Whitespace checks pass.
- The new regression's initial AppKit harness needed NSApplication initialization before the tracking-mode check; its corrected test passes. The first sandboxed launch was prohibited by the environment; the test completed under the authorized local test execution.
- Logs: `/private/tmp/ongaku-vu-response-build.log`; command output of the regression reports PASS. These local paths are not portable release artifacts.

## Limits and Pending

- ⭕️ [Pending] On iPhone SE (3rd generation) and iPhone 16 Pro Max, compare real playback and fast scrolling, foreground/background, pause/resume, quality handoff and effects ON/OFF; inspect all faces and confirm smooth needle motion with actual audio. Measure UI CPU/GPU load, dropped frames, battery/thermal cost and Low Power Mode behavior. Nominal 60 Hz does not guarantee 60 rendered frames per second.
- ⭕️ [Pending] Compare a known amplitude-modulated test signal through both apps on equivalent output conditions. The mobile analysis tap still requests 4096 frames versus Desktop's 1024: UI polling cannot restore transients that are already averaged in an audio measurement window. Any change to that tap must separately validate FFT resolution, meter audit coherence and load before changing it.
