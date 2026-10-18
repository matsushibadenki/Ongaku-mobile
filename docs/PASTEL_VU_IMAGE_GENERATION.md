# Pastel VU meter assets — 2026-10-18

Generated using the built-in `image_gen` tool. The four original outputs were copied unchanged into `audio/Assets.xcassets/VUmeter_pastel_{pink,purple,green,beige}.imageset/`. Each is an opaque 852 × 1846 PNG. Existing Original/Light/Dark meter assets remain intact.

The generated face is intentionally blank. `PastelVUMeterFace.swift` draws the brand, calibrated −20…+3 VU scale and needle in one coordinate system. Measured pivot: (426, 664); shallow scale arc: x = 218…634, y = 516 − 34 × sin(π × position). A small amber/green lamp preserves the normal/Precision Sinc distinction without changing the pastel enclosure. The complete image is aspect-fitted, and empty edges blend into the exact sRGB theme background.

## Pink

Asset: `audio/Assets.xcassets/VUmeter_pastel_pink.imageset/VUmeter_pastel_pink.png`

Final prompt:

Use case: precise-object-edit.
Asset type: production background image for an iPhone music app's analog VU meter.
Input image is the geometry reference and edit target. Redesign ONLY its meter object and backdrop, preserving the FULL portrait composition and precise position.
Replace the old wooden/brass industrial object with an adorable sophisticated pastel-pink collectible audio meter: generously rounded squircle enclosure, soft candy-pink ceramic/resin, subtly pearlescent surface, cream inner bezel, tiny blush-pink round fasteners instead of industrial screws, smooth tactile edges. Cute through proportions and material, no characters, no ears, no extra objects. Gentle upper-left studio lighting, small soft contact shadow, clean premium product rendering.
Backdrop: seamless uniform pale pink #fbeefa, all corners and the entire large empty lower half exactly this color. No horizon, no vignette.
CRITICAL geometry: same full portrait aspect ratio as input, about 852x1846. Meter outer bounds x=10.5%..89.5%, y=8.8%..43.5%. Inner blank dial window x=23%..77%, y=15.0%..37.6%; retain this generous wide rectangular window with soft rounded corners. Central needle pivot opening x=50%, y=37.95%, at the bottom center of the window. Preserve all empty space below. Front view perfectly parallel to image, zero perspective tilt.
CRITICAL remove ALL lettering, numbers, tick marks, scale arcs, logos and needles from the face. It MUST be an entirely blank warm ivory dial ready for precise app-rendered typography and calibrated scale. Do not draw a needle or a central pivot cap; just the subtle centered opening at the bottom. No text anywhere. No watermark, no UI. Keep the entire object uncropped. Output one opaque full portrait image.

## Purple

Asset: `audio/Assets.xcassets/VUmeter_pastel_purple.imageset/VUmeter_pastel_purple.png`

Final prompt:

Use case: precise-object-edit. Asset: production iPhone VU meter background.
Image 1 is the approved pastel-pink meter EDIT TARGET. Create its purple colorway.
Change ONLY pink enclosure and pink fasteners to soft lavender lilac ceramic/resin. Change the whole empty studio backdrop to the exact seamless pale purple color #eeecfe, especially edges/corners and the lower empty half. Keep the cream bezel and warm ivory blank dial, same glossy soft tactile finish, light, shadow, camera, framing and every object's pixel geometry. Keep the cute rounded shape, no additional objects.
STRICT: same 852:1846 portrait aspect ratio, no crop or resize/reposition of the meter relative to canvas. Preserve exact blank dial window and its bottom-center pivot opening. Preserve the entire large empty bottom region. NO lettering, logo, numbers, ticks, scale arcs, needle or pivot cap anywhere: app code overlays them. Single opaque portrait image. No watermark.

## Green

Asset: `audio/Assets.xcassets/VUmeter_pastel_green.imageset/VUmeter_pastel_green.png`

Final prompt:

Use case: precise-object-edit. Asset: production iPhone VU meter background.
Image 1 is the approved pastel-pink meter EDIT TARGET. Create its green colorway.
Change ONLY pink enclosure and pink fasteners to soft mint pistachio green ceramic/resin. Change the whole empty studio backdrop to the exact seamless pale green color #e1fff4, especially edges/corners and the lower empty half. Keep the cream bezel and warm ivory blank dial, same glossy soft tactile finish, light, shadow, camera, framing and every object's pixel geometry. Keep the cute rounded shape, no additional objects.
STRICT: same 852:1846 portrait aspect ratio, no crop or resize/reposition of the meter relative to canvas. Preserve exact blank dial window and its bottom-center pivot opening. Preserve the entire large empty bottom region. NO lettering, logo, numbers, ticks, scale arcs, needle or pivot cap anywhere: app code overlays them. Single opaque portrait image. No watermark.

## Beige

Asset: `audio/Assets.xcassets/VUmeter_pastel_beige.imageset/VUmeter_pastel_beige.png`

Final prompt:

Use case: precise-object-edit. Asset: production iPhone VU meter background.
Image 1 is the approved pastel-pink meter EDIT TARGET. Create its beige colorway.
Change ONLY pink enclosure and pink fasteners to soft vanilla biscuit beige ceramic/resin. Change the whole empty studio backdrop to the exact seamless pale beige color #faf7e3, especially edges/corners and the lower empty half. Keep the cream bezel and warm ivory blank dial, same glossy soft tactile finish, light, shadow, camera, framing and every object's pixel geometry. Keep the cute rounded shape, no additional objects.
STRICT: same 852:1846 portrait aspect ratio, no crop or resize/reposition of the meter relative to canvas. Preserve exact blank dial window and its bottom-center pivot opening. Preserve the entire large empty bottom region. NO lettering, logo, numbers, ticks, scale arcs, needle or pivot cap anywhere: app code overlays them. Single opaque portrait image. No watermark.

