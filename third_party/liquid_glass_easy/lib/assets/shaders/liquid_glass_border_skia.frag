// -----------------------------------------------------------------------------
// Liquid Glass border — Skia / web entry.
//
// Identical to liquid_glass_border.frag, but LIQUID_GLASS_SKIA selects the
// ANALYTIC gradient (no dFdx) so it loads on Skia/web. Loaded per-backend in
// Dart, exactly like liquid_glass_skia.frag.
// -----------------------------------------------------------------------------
#define LIQUID_GLASS_SKIA
#include "liquid_glass_border.frag"
