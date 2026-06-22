# Ink simulation

SketchCam's Ink layer is a GPU feedback simulation inspired by John Whitaker's
[Inkwash](https://github.com/johnowhitaker/inkwash). The original explanatory
article used while porting the model is `about.html` from that project. This
note records the algorithm in SketchCam terms and the extensions made here.

## State textures

The painting is stored as fields rather than display pixels:

- `ink` (`RGBA16F`) holds mobile optical-density pigment; alpha carries white
  dissolve/gouache coverage.
- `fixed` (`RGBA16F`) holds settled pigment that no longer advects.
- `locked` (`RGBA16F`) holds pigment made permanent by **Fix**. Wash never
  lifts this layer; **Unfix** returns it to `fixed`.
- `wet` (`R16F`) is the persistent water mask and the permission field for
  motion and diffusion.
- `velocity` (`RG16F`) is a deliberately lower-resolution fluid field.
- `pressure`, `divergence`, and `curl` are solver scratch fields.

The velocity grid stays coarse because liquid motion is smooth and pressure
projection is the expensive part. Pigment and wetness stay near output
resolution so edges, blooms, and granulation remain sharp.

## Per-frame solver

The simulation follows the Stable Fluids pattern:

1. Add brush or routed optical-flow forces to velocity.
2. Semi-Lagrangian advection traces each destination backward through velocity
   and samples the previous field. Pulling values this way is stable even with
   variable frame intervals.
3. Compute curl and apply vorticity confinement to restore small eddies lost to
   bilinear sampling.
4. Compute divergence, relax pressure with Jacobi iterations, then subtract the
   pressure gradient to project velocity toward incompressibility.
5. Advect wetness more slowly than velocity and let it creep into neighbors.
6. Advect and diffuse only the mobile pigment permitted by wetness.
7. Exchange mobile and fixed pigment according to drying/fixing.

All time-dependent coefficients use elapsed time rather than frame count.

## Wetness is the central material rule

The `wet` texture is not merely a visual sheen. It gates the physics:

- Dry pixels suppress velocity.
- Damp pixels allow limited pigment creep.
- Wet pixels permit strong advection, bleed, and brush lifting.
- Wetness itself advects at a fraction of the fluid speed, spreads by capillary
  creep, and evaporates according to Dry and Wet decay.

This explains the characteristic stop: the flow may still exist numerically,
but it cannot transport pigment after the permission mask dries. SketchCam adds
three ways to create that permission field:

- strokes deposit wetness (pen lightly, wash strongly);
- Option-drag is a water-only spray that deposits wetness without pigment or
  displacement;
- **Wet canvas** floods it once, while **Motion wetness** continuously injects
  wetness from routed optical-flow magnitude.

## Marks, pigment, and fixing

Strokes are overlapping radial/capsule splats. Pigment adds as optical density,
so repeated marks deepen naturally. Wetness uses max blending, so scrubbing an
area makes it wet rather than accumulating unbounded water.

Wash-loaded pigment uses bounded optical-density addition: ordinary marks are
unchanged through the useful density range, while extreme repeated scrubbing
soft-compresses further buildup. This prevents half-float/grid variations from
turning into a digital-looking residue without flattening normal overlap,
granulation, or fluid transport.

The wash adds water and directional velocity. Brush Ink controls fresh pigment
loading; Smear controls how strongly the wash remobilizes existing pigment.
Fix transfers all mobile and settled density into `locked`; Unfix returns it to
the ordinary settled layer. Wet Canvas fills the wetness field, while Dry Canvas
clears wetness and residual fluid momentum without moving or fixing pigment.

## Gesture-driven transition: dry smear to fluid swirl

A wash is a fluid impulse rather than a geometric brush mark. Cursor movement
is filtered, then each captured sample can wet, lift, and push pigment. This
creates an expressive transition that can feel like a phase change:

1. The wash always deposits water and remobilizes some settled pigment.
2. If the filtered per-sample movement is below the Smear threshold, it pools
   water but injects no velocity. The result is a dry-looking, paper-textured
   pull.
3. Above that threshold, cursor speed becomes a directional velocity impulse.
4. Wetness gates velocity through `smoothstep(0.005, 0.2, wet)` and pigment
   mobility through `smoothstep(0.02, 0.45, wet)`. Once these ranges are crossed,
   advection and diffusion become visually dominant.
5. Fast passes and repeated crossings inject stronger or opposing impulses.
   Vorticity confinement turns their shear into soft eddies and swirls.

At Smear `0.5`, the movement threshold is approximately `0.0058` of the canvas
per processed sample. Because this is a distance threshold on filtered samples,
not a pure speed threshold, the exact transition can vary slightly with input
event and frame cadence. This is a source of both expressiveness and some
unpredictability.

The relevant performance controls have distinct roles:

- **Smear** is the main onset control. Higher values lower the movement
  threshold, lift more settled pigment, and amplify brush force; the fluid phase
  begins sooner. Lower values preserve controlled, dry pulls longer.
- **Flow** controls injected force, velocity persistence, and vorticity. Lower
  values retain translation with less swirl; high values create energetic,
  long-lived eddies.
- **Dry** and **Wet decay** control how long the wet mobility gate remains open.
- **Bleed** controls pigment diffusion after mobility is available; it does not
  set the transition threshold.
- **Wash size** controls the area wetted and lifted. A larger connected wet area
  sustains fluid behavior more easily.

Smear affects brush input while dragging. Flow, Dry, Wet decay, Bleed, and the
paper response continue affecting an already-moving field after release.

Color separation is diffusion at different rates per density channel. The
red-absorbing component can travel fastest while the blue-absorbing component
lags, producing a cool fringe through simulated chromatography rather than a
drawn halo.

## Display and paper

Display converts density to light with Beer-Lambert attenuation:

```text
color = paper * exp(-density * inkStrength)
```

Because densities add, overlapping translucent marks darken without ordinary
alpha-stack artifacts. The final pass also applies paper fiber/tooth/grain,
granulation, edge darkening, wet sheen, tint, contrast, saturation, and
vignette.

Paper tooth and density-edge enhancement roll off only inside exceptionally
dense pigment pools. At those densities real pigment should obscure the paper;
leaving both boosts fully active amplified tiny dye-grid differences into a
solarized texture. White pigment uses the same dense-pool rolloff in its
coverage channel. Wet-paper tint is composited beneath white pigment, so an
active whiteout remains opaque rather than temporarily revealing the wetness
field as grey pixelation.

Paper has two roles. Its cached renderer supplies the visible substrate, while
the physical-response fields can independently modulate absorbency, drag, and
resistance. A routed layer uses that layer's post-effect output, so Threshold or
Levels can turn a camera/movie image into a deliberate material mask.

The three material fields act at different stages:

- **Ink resist** reduces fresh pigment deposition and creates broken, waxy gaps
  in a stroke. It does not resist pigment that has already been lifted.
- **Flow drag** damps velocity and mobile-pigment advection everywhere, including
  fully wet flow.
- **Absorb** increases local capillary spread and wetness decay.

Paper therefore still affects wet flow, but a fast wash can visually overpower
it: the brush repeatedly restores high wetness, its velocity impulse is much
larger than one frame of paper drag, and projection/diffusion smooth fine-scale
material differences. To retain more substrate character in a fluid passage,
increase Material Variation and Flow drag, reduce Flow, or type a Paper influence
above the slider range (roughly `2...4`). If stronger influence perforates fresh
marks too much, reduce Ink resist while retaining Flow drag and Absorb.

The current paper model does not modulate brush re-wetting or fixed-pigment
lifting. A wash can always make its footprint wet and lift settled pigment. A
future independent wet-grip/rewet-resistance control could reuse the cached
paper maps without adding another renderer.

## Gesture history and exact physical undo

Completed pen and wash gestures are stored as canonical timestamped actions.
Their captured timing preserves the speed-derived width and force profile used
while drawing. The action log remains the semantic source for future path and
gesture editing.

Replaying a fluid gesture is not, by itself, an exact undo mechanism: wash
forces are injected over real display frames while drawing, whereas a replay
necessarily compresses that interaction into a different solver schedule.
SketchCam therefore retains a bounded ring of complete Metal simulation states
at action boundaries. Each state contains mobile pigment, fixed pigment,
wetness, velocity, pressure, and locked pigment. Undo and redo restore these
fields directly when a matching state is available; older actions fall back to
deterministic replay.

**Settings → Ink Undo → GPU states** controls the ring depth. The UI estimates
memory from the active output format. Apple silicon uses unified memory, so the
ring is capped at 50% of physical RAM and warns above 25%. Zero disables exact
state retention. Changing the value affects newly captured gestures.

The longer-term action-checkpoint service should also support temporary sparse
states on disk. Those recoverable simulation checkpoints are distinct from
flattened timelapse frames, but both should share the same action index and
auto-frame-on-action event. Temporary checkpoint storage must be removed when
the application exits.

**Live surface** is separate from procedural paper. It uses optical-flow
magnitude from a changing routed Ink texture input. With **Internal paper** and
no routed texture, it has no live signal and should be left at zero.

## Human motion and analysis effects

The default motion provider computes forward optical flow from the routed Ink
texture (previous frame to current frame). Direction is converted to canvas
velocity and injected before fluid projection. It only moves pigment where the
wetness gate allows it.

Optical Flow is also available as an ordinary order-sensitive layer effect for
inspection or further processing. Direction is encoded in red/green and speed
in brightness. Levels and Threshold can be placed before or after it to isolate
useful motion or material regions.

## Controls and reset convention

Double-click any numeric parameter label to restore its factory default. This
includes Paper settings, Material map, Ink response, effect parameters, Acrylic
controls, and the bottom Ink HUD. Editable numeric fields can be typed beyond
their slider range for experiments.

Canvas-state shortcuts are:

- `Control-Option-F`: Fix
- `Shift-Option-F`: Unfix
- `Control-Option-W`: Wet Canvas
- `Shift-Option-W`: Dry Canvas
- `Command-Z`: undo the last canvas action
- `Command-Shift-Z`: redo the last canvas action
- `Command-Shift-R`: redo the last canvas action (future repeat-action/macro key)
