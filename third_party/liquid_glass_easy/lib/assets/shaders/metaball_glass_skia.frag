// -----------------------------------------------------------------------------
// Metaball Liquid Glass — Skia / web entry.
//
// Identical to metaball_glass.frag (the Impeller entry) except for the merged-
// field gradient. Skia's SkSL has no dFdx(float), so the derivative-based 1-tap
// shapeFrom1Tap is invalid there and would make the WHOLE program fail to load —
// a runtime uniform can't rescue it, the compiled program must contain no dFdx.
//
// Defining METABALL_SKIA before the include leaves GLASS_USE_DERIVATIVE_GRAD
// undefined (dFdx never compiled) and selects the ANALYTIC merged gradient
// (METABALL_GRAD_ANALYTIC 1) — the smooth-union's exact gradient from the
// per-lens rounded-rect gradients, one pass, valid on every backend.
//
// The Dart side (LiquidGlassBlender) detects the backend and loads this file on
// the Skia capture path and metaball_glass.frag on the Impeller path — so the
// backend split lives in Dart, not in a shader preprocessor probe.
// -----------------------------------------------------------------------------
#define METABALL_SKIA
#include "metaball_glass.frag"
