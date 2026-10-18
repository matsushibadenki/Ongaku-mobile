# Mobile pastel appearance validation — 2026-10-18

The initial appearance checks below predate the detailed dial refinement. For the current dial and Mac parity, see [the updated validation](PASTEL_DESKTOP_PARITY_VALIDATION.md).

## Implementation

| Appearance | Background (sRGB) | Accent |
| --- | --- | --- |
| Pink / ピンク / 粉色 | `#fbeefa` | `#a83f79` |
| Purple / パープル / 紫色 | `#eeecfe` | `#7051b4` |
| Green / グリーン / 绿色 | `#e1fff4` | `#24765b` |
| Beige / ベージュ / 米色 | `#faf7e3` | `#856122` |

All four choices use the light interface, dark text and coordinated controls. Selection uses the existing persisted appearance setting. Original, Light and Dark remain available, for seven choices in total.

Four new rounded ceramic/resin VU enclosures were generated with the built-in image tool. The 852 × 1846 outputs are stored unchanged in the asset catalog. SwiftUI draws the dial typography, −20…+3 VU ticks and animated needle using a common coordinate system: pivot (426, 664), shallow scale arc x = 218…634, y = 516 − 34 × sin(π × position). The entire object is aspect-fitted; empty image edges blend into the exact theme background. A small amber/green lamp distinguishes ordinary playback and Precision Sinc. See [asset paths and exact generation prompts](PASTEL_VU_IMAGE_GENERATION.md).

## Verification

- 🟢 [Done] Ordinary Debug iOS Simulator build: `xcodebuild -project Ongaku.xcodeproj -scheme audio -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/ongaku-pastel-ios CODE_SIGNING_ALLOWED=NO build` succeeded.
- 🟢 [Done] The production-view audit passed six result groups on both iPhone SE (3rd generation) and iPhone 16 Pro Max. It checks all four exact RGB backgrounds, saved selection values, asset existence/size, English/Japanese/Simplified Chinese labels, finite in-window needle endpoints and a scrolling appearance picker.
- 🟢 [Done] Captured 18 images per device: four production player screens, twelve isolated dials (minimum / 0 VU / maximum in each color), and the top/bottom of the appearance picker. Inspected representative screenshots across all four colors and both sizes. Dial text stays inside the window; the needle aligns at −20, 0 and +3 VU; the lower picker choices and preview controls remain reachable. Player controls fit on both sizes.
- 🟢 [Done] Invalid and out-of-range meter telemetry clamps to a finite needle location. The display-only change does not modify the audio processing path.
- ⭕️ [Pending] Confirm physical screen color reproduction, including True Tone/Night Shift, and live VU animation/readability during real playback. Simulator captures do not establish device color appearance or live rendering performance.

The audit uses the real `ContentView`, `AppearanceView` and meter components, with the initial visualization set to VU in the temporary test copy. It does not play audio. Japanese was used for screenshot inspection; English and Simplified Chinese label resolution was checked programmatically. Persistence checks cover the stored value, not a separate process-relaunch test. The Pro Max run reused the same audit binary that passed on SE.

Reproduce with `bash tests/run_pastel_appearance_audit.sh <simulator-uuid> <output-directory>`.

## Saved evidence

- [SE result](measurements/pastel-appearance-2026-10-18/se-pastel-result.txt) · [Pro Max result](measurements/pastel-appearance-2026-10-18/promax-pastel-result.txt)
- SE 0 VU: [pink](measurements/pastel-appearance-2026-10-18/se-dial-pink-20.png) · [purple](measurements/pastel-appearance-2026-10-18/se-dial-purple-20.png) · [green](measurements/pastel-appearance-2026-10-18/se-dial-green-20.png) · [beige](measurements/pastel-appearance-2026-10-18/se-dial-beige-20.png)
- Appearance picker: [SE](measurements/pastel-appearance-2026-10-18/se-appearance-bottom.png) · [Pro Max](measurements/pastel-appearance-2026-10-18/promax-appearance-bottom.png)
- Pro Max: [production green player](measurements/pastel-appearance-2026-10-18/promax-now-playing-green.png) · [purple at +3 VU](measurements/pastel-appearance-2026-10-18/promax-dial-purple-23.png)
