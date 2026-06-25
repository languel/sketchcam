# Stroke architecture refinement — paths primary, pluggable renderers

Branch `codex/drawing-fixes`. Goal: paths are the primary data; ink/wash/etc. are
*renderers* that draw from strokes. Rich path schema (per-nib timing + expression)
so strokes can be edited, re-rendered, and replayed over a time window; multiple
path-rendering algorithms (tldraw-style filled ribbon, watercolor wash, splashes,
generative…).

## What we have today
- **`InkLiveStrokePoint`** = `{ point, time }` only. Pressure/velocity are derived
  *in the engine* from speed each frame and then thrown away — never stored.
- **`InkEditorPath`** = points + optional sampleTimes + stroke-level params
  (brushMode, inkKind, width, flow, bleed, dry, colorSeparation, brushInk, color,
  brushSpace). No per-nib pressure/velocity/width; no renderer selector.
- **Pen render = immediate-mode nib stamping into the fluid dye** (splat/
  splatCapsule). This is the source of the beaded/dotted look — overlapping caps,
  per-step variation, no single continuous outline.
- **`StrokeTessellator` + `MetalLineRenderer` ALREADY EXIST** and produce exactly
  the wanted look: `appendRibbon` builds a filled triangle-strip with miter-joined
  left/right offsets around the centerline (variable width, no beads); rendered to
  an IOSurface with 4× MSAA. Used by LineWalk/Yarn/Wrap + LandmarkOverlayCompositor
  — but NOT by the pen. This is the "beautiful tldraw-style" renderer, already here.

## Proposed model (Core, Codable)
```
struct Stroke {                 // the primary, editable unit
    id: UUID
    nibs: [Nib]                 // the rich centerline
    space: BrushSpace           // screen | world (size interpretation)
    renderer: StrokeRendererKind// .ribbon | .inkWash | .splash | .generative …
    brush: BrushParams          // size, color, flow, bleed, dry, brushInk, … (renderer reads what it needs)
    seed: UInt64
}
struct Nib {                    // one sample along the path
    position: CGPoint           // world-normalized
    t: TimeInterval             // seconds from stroke start (enables time-window replay)
    pressure: Float             // 0…1 (captured or derived-then-stored)
    speed: Float                // normalized units/sec (for taper, splash triggers…)
    // room to grow: tilt, azimuth, twist, custom expression channels
}
```
`Nib` carries everything a renderer needs; `BrushParams` are stroke-level knobs a
renderer interprets. A Document holds `[Stroke]` (this is the layer's content).

## Renderer protocol
```
protocol StrokeRenderer {
    /// Render strokes into the target. `window` (optional) limits to nibs whose t
    /// falls in range → one-stroke-at-a-time, time-stretch playback, progressive
    /// reveal. `ctx` carries the camera (so world strokes re-rasterize crisp at the
    /// current zoom — vector, not baked).
    func render(_ strokes: [Stroke], window: ClosedRange<TimeInterval>?, ctx: RenderContext, into: Target)
}
```
Implementations:
- **RibbonRenderer (tldraw / perfect-freehand)** — the pen baseline. Build the
  variable-width filled outline from nibs (width = f(pressure, speed) smoothed),
  tessellate (`StrokeTessellator`, extended so the half-width profile reads per-nib
  width), rasterize via `MetalLineRenderer` (MSAA) at OUTPUT resolution every frame
  → smooth, crisp, zoom-independent. No fluid dye.
- **InkWashRenderer** — the existing fluid sim, but consuming the SAME `Stroke`
  nibs (watercolor wash, where granulation/bleed is wanted). Pen ≠ wash: pen uses
  RibbonRenderer, wash uses InkWashRenderer.
- **Future**: SplashRenderer (spatter on high `speed` nibs), GenerativeRenderer,
  per-nib stamp brushes, etc. — all just new StrokeRenderers over the same schema.

## Live stroke
The active stroke (mousedown→up) streams nibs and re-renders each frame; it MAY
evolve slightly as it lands (perfect-freehand-style smoothing) — fine, because the
stored `Stroke` is the source of truth and re-renders identically on edit/replay.

## Phasing
1. **Schema (Core):** add `Stroke`/`Nib`/`BrushParams`/`StrokeRendererKind`; capture
   per-nib pressure+speed live (extend the live channel); migrate `InkEditorPath` →
   `Stroke` with back-compat decode (old paths → ribbon/inkWash by brushMode).
2. **Ribbon pen renderer:** route pen strokes through StrokeTessellator +
   MetalLineRenderer (variable width from nib pressure/speed); composite as the pen
   layer; retire pen nib-stamping. ← fixes the beading definitively.
3. **Wash renderer:** keep the fluid sim, fed by the same strokes (pen→ribbon,
   wash→fluid via `renderer`/`brushMode`).
4. **Renderer protocol + selector** formalized; per-stroke renderer kind in UI.
5. **Time-window playback + new renderers** (splash, generative).

Also: a stray bug — pen size persisted to 0.2 (sub-pixel → isolated dots); the new
sizing is literal px, so just set a sane default/clamp-floor for display.

Biggest immediate win = Phases 1–2 (schema + ribbon pen). Wash stays as-is until 3.
