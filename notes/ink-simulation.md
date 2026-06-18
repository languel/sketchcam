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

The wash adds water and directional velocity. Brush Ink controls fresh pigment
loading; Smear controls how strongly the wash remobilizes existing pigment.
Fix transfers mobile density into `fixed`, brakes velocity, and dries the area,
allowing later glazes to move without reviving the settled layer.

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

Paper has two roles. Its cached renderer supplies the visible substrate, while
the physical-response fields can independently modulate absorbency, drag, and
resistance. A routed layer uses that layer's post-effect output, so Threshold or
Levels can turn a camera/movie image into a deliberate material mask.

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
includes the Ink paper controls, Paper Physical response, effect parameters,
Acrylic controls, and the bottom Ink HUD.
