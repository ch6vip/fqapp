// -----------------------------------------------------------------------------
// Liquid Glass — Skia / web entry.
//
// Identical to liquid_glass.frag, but defining LIQUID_GLASS_SKIA before the
// include selects the ANALYTIC gradient (GLASS_GRAD_METHOD 1) instead of the
// hardware derivative — SkSL has no dFdx(float), so the derivative path must
// never be compiled here or the whole program fails to load. The Dart side
// loads this file on the Skia capture path and liquid_glass.frag on Impeller.
// (LIQUID_GLASS_FORCE_5TAP overrides both backends to the 5-tap.)
// -----------------------------------------------------------------------------
#define LIQUID_GLASS_SKIA
#include "liquid_glass.frag"
