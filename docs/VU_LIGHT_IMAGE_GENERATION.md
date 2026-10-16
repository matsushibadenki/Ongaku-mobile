# Light VU meter image generation

Generated on 2026-10-16 using the built-in image_gen tool (not CLI).
Both outputs are opaque 852 × 1846 PNG images, copied unchanged into the asset catalog. Original assets remain intact. Runtime aspect-fit preserves the full composition; only empty background edges blend into the app's glossy background. The existing normalized needle geometry is reused.

## Orange

Asset: `audio/Assets.xcassets/VUmeter_orange_light.imageset/VUmeter_orange_light.png`

Final prompt:

Use case: precise-object-edit.
Image 1 is the edit target: the current orange VU meter background asset for a native iPhone music app.
Replace ONLY the dark charcoal studio wall and rough dark tabletop outside the VU meter with a seamless luminous white studio background/satin glossy white surface. Palette: #ffffff at the upper left, #fbfbfb through the middle, #f4f4f4 near the lower right. Very subtle soft contact shadow immediately beneath the meter, no gray vignette, no visible horizon, no rough concrete texture, no strong reflection. The large bottom negative space should be nearly uniform clean white, smoothly shaded.
STRICT invariants: preserve the entire portrait composition, camera, meter position and size, wooden and aged brass housing, four screws, orange illuminated face, all original lettering and tick marks exactly. Do not redesign or recenter the meter. No crop. Do not add a needle (the app draws it). Keep the pivot opening and all scale marks in the exact same normalized coordinates; pivot at x=50%, y=37.95%. Meter outer bounds approximately x=10.5% to 89.5%, y=8.8% to 43.5%. Preserve all blank space below.
Text unchanged: "#Ongaku", "PROFESSIONAL VU METER", "VU", "dB", all existing numbers. No new text, decorations, UI, watermark.
Output a single full portrait image matching the input aspect ratio 1170:2532, ideally 1170x2532. Photorealistic, high fidelity. Opaque white background.

## Green

Asset: `audio/Assets.xcassets/VUmeter_green_light.imageset/VUmeter_green_light.png`

Final prompt:

Use case: precise-object-edit.
Image 1 is the edit target: the newly generated white-background orange VU meter. Image 2 is ONLY a color reference for the yellow-green backlight.
Change ONLY the orange illumination within the meter glass of Image 1 to the yellow-green illumination of Image 2. Preserve all other pixels and composition of Image 1 as closely as possible: luminous white studio background, subtle contact shadow, wooden/brass housing, exact meter size/position, scale, printed text and screws. Do NOT copy the dark wall or gray tabletop from Image 2. Keep white background and bottom negative space exactly as Image 1.
Strict geometry: unchanged full portrait aspect ratio, no crop, no scaling or repositioning. Needle pivot remains x=50%, y=37.95%. Do not draw a needle; the app overlays it. Preserve "#Ongaku", "PROFESSIONAL VU METER", "VU", "dB" and all numbers/ticks. No added objects, UI or watermark. Single opaque portrait output.

