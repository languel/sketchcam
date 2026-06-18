# Acrylic Medium Design

## Goal

Add a liquid acrylic medium beside the existing Ink simulation. Acrylic must range continuously from acrylic ink or glaze through fluid acrylic to heavy body, mix while wet, dry irreversibly, and allow light paint to cover dried black Ink. Ink and Acrylic remain independent layer solvers and meet through normal layer compositing.

## Simulation state

Each Acrylic layer owns GPU textures for wet paint thickness, color mass, velocity, binder wetness, dried thickness, and dried color. Wet thickness and color move together, while binder wetness controls mobility and mixing. Drying transfers wet material into the immobile dried textures without changing its visible color or coverage.

New strokes deposit paint above existing dried acrylic and mix wherever they contact wet material. Dried paint is never dissolved by ordinary painting. An explicit future solvent tool is outside this design.

The solver consumes shared paper scalar fields and live vector fields with Acrylic-specific strengths. Resist affects deposition, Drag affects movement, Absorbency affects binder loss and edge behavior, and motion vectors inject bounded velocity.

## Body and controls

`Body` is the primary macro and defaults to fluid acrylic. Low Body lowers coverage and viscosity while increasing flow and leveling, producing acrylic-ink and glaze behavior. High Body increases coverage, viscosity, brush retention, and thickness relief while reducing self-leveling.

Advanced controls expose pigment opacity, viscosity, leveling, brush retention, paint loading, flow, Dry Rate, Paper Influence, live surface influence, and motion force. Moving Body writes a coordinated set of these material values; subsequent advanced edits change individual values without moving Body. Moving Body again reapplies the coordinated set. Dry Rate may be zero. An Instant Dry action transfers all current wet paint into the dried state.

## Color mixing and rendering

Each deposited stroke selects one of two mixing rules:

- **RGB** mixes linear-light color by wet paint mass for clean, predictable results.
- **Pigment** uses an absorption/scattering approximation weighted by pigment mass for darker, more physical mixtures.

Changing the selected rule does not reinterpret untouched existing paint. The current rule applies to new deposits and to wet pixels they contact; pixels not touched or remixed retain their prior result.

Rendering derives coverage from pigment opacity and total thickness rather than treating color as translucent Ink density. This allows pale opaque paint to cover black layers. Wet and dried thickness share the same coverage calculation, while wetness may add a restrained sheen. A screen-space normal derived from thickness supplies inexpensive relief and edge shading for high-body paint without geometry or CPU processing.

## Layer behavior and compatibility

Acrylic is a separate drawable medium/layer source with its own retained strokes, undo/redo history, clear, rebuild, and dry actions. Acrylic layers use existing visibility, opacity, ordering, and blend controls. Placing Acrylic above Ink provides overpainting; reversing layer order remains possible. Wet Ink and wet Acrylic do not exchange fluid or pigment in this version.

Existing projects decode without Acrylic layers and are unchanged. Acrylic resources are allocated only when a layer exists and is active.

## Validation

Acceptance scenes cover pale acrylic over dried black Ink, wet-on-wet RGB and Pigment mixing, untouched paint remaining unchanged after a model switch, gradual and instant drying, overpainting dried acrylic, and the complete Body range. High Body must retain stroke topology and show thickness relief; low Body must flow and level without becoming the existing watercolor solver. Tests verify mass and thickness bounds, finite values under extreme controls, dry-state immobility, zero-cost absence of Acrylic layers, deterministic stroke replay, and GPU timings separated from Ink and control-field work.
