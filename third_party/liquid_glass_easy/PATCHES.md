# Wenku8 performance patch

## 2026-10-26 — Specialize mathematically absent optics

The Impeller lens selects `liquid_glass_unlit.frag` only for circular rounded
rectangles with all three light thicknesses and dispersion exactly zero. This
entry includes the general shader with unused corner, lighting and chromatic
sampling branches compiled out. Refraction, derivatives, AA, deformation,
transforms, live input, blur, saturation and tint use the same equations and
parameters. Changing the style restores the general program in the same frame.
Skia and desktop retain their existing programs.

The GLES3 compiler emits 690 rather than 2285 SPIR-V instructions, and 8421
rather than 38175 bytes of GLSL. The 22 uniform names, locations and vector
sizes match, so the existing uniform packer is unchanged. These are static
program-size measurements; physical-device timing is evaluated separately.

`integration_test/glass_unlit_shader_test.dart` compared both programs on the
iOS 26.5 iPad simulator's Impeller renderer: 13 states of three lenses at 2x
pixel capture had maximum channel difference 0. Capsule, circle, blur, live
background, translation, width, theme tint, grouping, and switching to/from
lit/other-corner/dispersion styles are covered. Pixels inside the capsule
changed with the live source. `LIQUID_GLASS_SPECIALIZE_UNLIT=false` selects the
general program for matched measurements, without changing material parameters.

## 2026-10-26 — Retain unchanged native filter instructions

The Impeller lens still resolves live scene geometry before every submission.
When its immutable image filter and backdrop input group have not changed, the
empty shader layer now uses `SceneBuilder.addRetained` instead of creating
another native backdrop-filter layer. It retains the filter instruction, not a
background image: scrolling pixels remain live. Geometry, material and input
group changes submit a new instruction in the same frame.

`integration_test/glass_filter_layer_retention_test.dart` compares retention
disabled/enabled on the iOS 26.5 iPad simulator's Impeller renderer. Sixteen
changing-background frames with two lenses (clear and blurred) required 32
native filter pushes before and 0 after, replaced by 32 retained instructions.
Six captured states, including movement, width, tint and batch changes, had
maximum RGBA channel difference 0; pixels inside both stationary lenses changed
with the live source. Physical-device raster/thermal benefit is measured
separately. `LIQUID_GLASS_RETAIN_FILTER_LAYERS=false` retains the previous path
for matched measurements without changing optical parameters.

## 2026-10-18 — Share geometry prefixes within one scene

Moving lenses now share their ancestor-surface lookup and render-transform
prefixes through the current `SceneBuilder`. Matrix multiplication retains
Flutter's root-to-leaf order. The scene-only cache is discarded with its
builder, so scrolling, route motion, opacity subpasses and overscroll filters
resolve fresh coordinates on every frame. The actual layer-clip traversal and
all optical parameters remain unchanged.

`test/glass_scene_geometry_test.dart` compares the cached matrices and subpass
identity against Flutter's original lookups in four changing scenes. Twelve
lenses with ten shared ancestors require 10 rather than 120 ancestor-transform
applications per scene, with exactly matching matrices. Native clipped,
rotated, fading and filtered pixel comparisons are in
`integration_test/glass_uniform_retention_test.dart`.
Android API 35 / Impeller OpenGLES produced identical pixels in all four
scenes (maximum channel difference 0). This is geometry-cost and rendering
evidence; target-device frame times still need physical-device validation.

## 2026-10-18 — Retain unchanged lens uniforms and filters

The Impeller lens still resolves its actual transform and ancestor clip at scene
composition. If geometry, clipping, material, shader and sampling frame are
unchanged, it now reuses its packed uniforms and immutable image filter instead
of uploading the same parameters and creating another native filter every
frame. Background pixels remain live; movement invalidates the retained state
in that same frame. Blur sigma, refraction, tint, shapes and animation timings
are unchanged.

`integration_test/glass_uniform_retention_test.dart` compares the previous path
with retention on Android API 35 / Impeller OpenGLES. Sixteen changing-background
frames caused 18 repeated packs before and 0 after; the moved-lens output had
maximum channel difference 0. This verifies eliminated repeated parameter work
and pixel parity, not Xiaomi 14 frame rate.

## 2026-10-17 — Share scroll-edge input, not its masked result

`LiquidGlassScrollEdgeGroup` gives a separated top/bottom pair one backdrop
input. Each edge retains its original Gaussian sigma, clip, plateau, eight-stop
feather and independent `dstIn` output. Different filters prevent Impeller's
equal-filter result coalescing, which is incompatible with these internal masks.
The page's glass controls never join this input group. Nested pages own fresh
groups; overlapping Gaussian halos, additional bands and partially transparent
routes keep the previous independent-input path.

The implementation uses Flutter's native Impeller backdrop IDs. It adds no
platform view, CPU frame readback, sampled-frame cache or reduced-quality kernel.
Outside this new group the upstream scroll-edge batch behavior is preserved.

Validation: identical source pixels on Android API 35 / Impeller OpenGLES,
maximum and mean channel differences both zero. Live-source movement, overlapping
bands and alpha transitions are checked in `integration_test/scroll_edge_input_test.dart`.
The host emulator is capped at 60 Hz; its profile trace does not establish a
physical-device 120 fps result.

References: [Flutter BackdropFilter](https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html),
[Impeller backdrop input and result caching](https://github.com/flutter/flutter/blob/master/engine/src/flutter/impeller/display_list/canvas.cc).

Based on the unmodified **liquid_glass_easy 5.0.0** pub.dev source archive,
by Ahmed Gamil. The upstream MIT license is retained in `LICENSE`.

Source: https://pub.dev/packages/liquid_glass_easy/versions/5.0.0
Upstream: https://github.com/AhmeedGamil/liquid_glass_easy

## 2026-10-15 — Bound single-lens shader output

`lib/assets/shaders/liquid_glass.frag` returns transparent pixels outside the
lens's output box before evaluating its shape, normals, refraction, lights and
texture samples. A derivative guard includes the antialiasing band and expands
under inverse ancestor transforms, preserving rounded, continuous, squircle,
scaled, rotated and flex-deformed edges.

The material equations, backdrop coordinate mapping, sampling, public widgets,
gestures, blender and morph APIs are unchanged. No screen captures, frame-rate
limiter, lower-resolution glass or static backdrop is introduced.

Native pixel validation lives in the host app at
`integration_test/easy_glass_pixels_test.dart`. Profile timing comparisons use
identical scenes and settings. Record device/GPU identity with timings;
emulator results do not establish physical-device FPS.

The vendored pubspec omits the pub.dev screenshot entry because the publishing
thumbnail is not included in the app's source distribution.

## Physically rounded menu morphs

The opt-in `LiquidGlassLens.physicalOptics` keeps a host-clipped rounded plate's
radius, refraction width and Gaussian blur in screen units under positive,
axis-aligned ancestor scales. Foreground layout remains host-owned. Normal
lenses, rotations and existing callers keep the upstream local-space contract.
This preserves the app's circular menu origin without relaying out its labels.

## Stable batch inheritance

`LiquidGlassBatch.inherit` keeps the enclosing backdrop key while enabled and
isolates the subtree while disabled. The scope stays mounted across changes,
preserving focused inputs and their platform connections as a lens settles.
The existing batch and exclude constructors keep their original behavior.

## 2026-10-16 — Opacity subpass coordinates

`liquidGlassFilterSubpassAncestor` recognizes partial `OpacityLayer` alpha
(1–254) in addition to `ImageFilterLayer`, so the shader uses the fading plane's
coordinates. Alpha 255 takes the engine's direct-paint path, not an opacity
subpass. Reader header and dock have separate batch
keys because their opacity textures are different backdrop surfaces. The
native reader integration captures full, half, low and zero-opacity states.

## 2026-10-16 — App form controls

The app uses the package's `LiquidGlassSwitch`, `LiquidGlassSlider` and inline
`LiquidGlassSegmented`, with its own milk/stone palette. The pinned fork exports
the inline selector and adds disabled-item semantics and focus feedback. Label
alpha is preserved when applying the disabled treatment.

Switch, slider and motion pill accept opt-in `reduceMotion`; defaults retain the
upstream springs, finger-follow, rubber band and glass deformation. The slider
also accepts opt-in `minimumTouchHeight` (default zero). Its release reconciles
controlled/quantized values, and its initial gesture value matches its initial
thumb. The switch does not request an unused raster snapshot on Impeller.
Slider capture starts only when its motion pill actually exposes glass. A
zero-frame tap can no longer leave Skia's capture pump running after release.

The app adapters reserve the complete swell footprint, add controlled async
switch values, slider divisions, disabled input, keyboard and screen-reader
actions. They do not replace the package's gesture simulation or lens renderer.

## 2026-10-16 — Premultiplied tint at antialiased edges

The shared `applyLensTint` mixed an already coverage-multiplied backdrop toward
an unmultiplied tint using tint-alpha × coverage. This added an extra
`alpha × coverage × (1 − coverage) × backdrop` term. With the optical lights
disabled, light paper presets still developed a white outline.

Tint now mixes in the same premultiplied coverage space as the backdrop. The
interior tint, refraction, optical lights, uniform emission and shader's shape
coverage are unchanged. Both single-lens and metaball shaders share this fix.
`integration_test/support/glass_tint_edges.dart` compares actual Impeller pixels
on uniform sage/parchment/night papers; zero-light pixels must not exceed either
input color. Before repair the sage/parchment cases exceed the allowed channel
ceiling by 16/21, respectively; night already passes.

## 2026-10-16 — Scrollable form gestures and cancellation

Switch and slider add opt-in `horizontalDragOnly`, enabled by the app adapters.
An axis-aware horizontal-drag/tap team lets vertical gestures scroll the parent
instead of capturing them and accidentally changing settings. The upstream
eager grab remains the default for other callers. Lens rendering, rubber band,
thumb deformation and settling springs are unchanged.

Slider cancellation settles to the last preview rather than interpreting a
short cancelled drag as a new track tap. A vertical switch cancellation does
not toggle. Both controls retain one gesture team through their rebuilds.
