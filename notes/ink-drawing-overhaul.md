# Ink drawing overhaul (branch `codex/drawing-fixes`)

Branched from `codex/canvas-foundation` to fix pen/wash sizing + rendering.

## Model: world vs viewport
`CanvasCamera` (center / viewHeight=zoom / rotation) + `CanvasRenderContext`
(worldPixelExtent=8192, worldHeight, brushSpace). Viewport is a camera over a
larger world. Brush spaces: **screen** (zoom-independent apparent px) and
**world** (fixed world-backing px, rescales on zoom).

## DONE — Stage 1: sizing overhaul (commits 2c34b5b, caebed1)
Root bugs that were fixed:
- Live and committed/replay strokes used two **unrelated** size formulas
  (`directRadius` vs the `sizeMult`/`penRadius` curve) and committed paths threw
  the live radius away → a stroke changed size the moment it committed/undid.
- Multiple `[0,2]` clamps (`clampedInkBrushSize`, `normalizedSize`, `sizeMult`,
  `min(uiSize,2)`) cropped typed values; ranges were skewed to the low end.

Fix: ONE resolver `MetalInkEngine.resolveBaseRadius(uiSize, space)` against the
live camera, used by **both** live and replay. `width` is now a literal apparent
DIAMETER in pixels; `InkEditorPath`/`InkLiveStrokeSample` carry `brushSpace`.
Removed the old curves and the UI pre-bake (`engineWidth`/`directBrushRadius`).
Bindings floor at 0 only (typed values exceed the slider range). Ranges: screen
0.25…256, world 1…2048; defaults pen 6, wash 48. Pen width is EMA-smoothed along
the stroke to reduce edge beading. Ink self-check updated + PASS. Verified live:
size-6 pen draws a sensible, correctly-sized stroke; manual entry works.

## TODO — Stage 2: smooth, crisp, zoom-independent VECTOR pen
Remaining problem (seen live): the pen still renders **beaded / not smooth**. It
is stamped as overlapping round capsules into the watercolor **fluid dye** (a
fixed-resolution raster fed to the sim + wet halo), so:
- the edge scallops (overlapping caps + per-step density variation), and
- committed strokes are baked into the dye and only re-rasterized when the path
  set changes — so zooming magnifies a raster (pixelation), it is NOT redrawn
  from the vector path at the new zoom.

Plan: render the **pen** as a tessellated **vector ribbon** at output resolution
with analytic/MSAA AA, re-rasterized from the path every frame — NOT through the
fluid dye. The repo already has the pieces: `StrokeTessellator` (Core, pure) +
`MetalLineRenderer` (IOSurface, MSAA) used by the LineWalk drawings. Route pen
`InkEditorPath`s → StrokeTessellator (variable width from the same
`resolveBaseRadius`) → MetalLineRenderer → composite over/under the wash. Keep
the fluid dye for the **wash** (where granulation is wanted). This gives a
smooth, crisp, zoom-independent pen and kills the beading + pixelation together.

Open question for the next session: composite order of the vector-pen layer vs
the wash dye, and whether wash also wants a partial vector pass.
