# Infinite canvas and recorded performance

SketchCam projects are versioned `.sketchcam` packages. `manifest.json` holds
the editable scene and performance; `Tiles/` holds sparse raster artifacts;
`Checkpoints/`, `Media/`, and `Previews/` reserve durable homes for simulation
snapshots, armed source proxies, and thumbnails.

## Coordinates and camera

The authored plane uses isotropic, unbounded world coordinates. At reset the
camera is one world unit high and its width follows the output aspect. Camera
center, view height, and rotation map world points to local viewport UV only at
the rendering/input boundary. Consequently a unit is the same physical length
in portrait, square, and landscape frames.

Space-drag or middle-drag pans; trackpad scroll pans; Command-scroll or pinch
zooms around the pointer; trackpad rotation rotates the camera. The active fluid
solver remains output-sized. When the camera changes, settled output is frozen
into 512-pixel world tiles. Tiles use LOD levels, an LRU memory cache, and a
lossless temporary backing store before package save, so navigation does not
grow GPU allocation with world size. The camera's default guard is five percent
and tile queries include the rotated world bounds. Offscreen raster is inert and
does not rewind when timeline time changes.

## Gestures and geometry

With Master Record off, drawing changes only the persistent raster artifact.
With it on, every gesture also stores raw samples (world position, relative
time, pressure, tilt, and modifiers), brush/material values, and an editable
cubic curve. Polyline, Catmull-Rom, Hobby and Bezier are reversible fit recipes;
manual anchor or tangent movement becomes a custom override and Refit rebuilds
from the preserved performance samples.

Selection is direct: click and drag objects, marquee empty space, Shift adds to
selection, Option-drag duplicates, and double-click or Enter edits anchors.
Clicking a selected segment inserts an anchor; tangent dragging is symmetric
unless Option is held; Delete removes anchors or objects; Escape returns to
object selection. Expressive previews are generated from the centerline plus
pressure using size, thinning, smoothing, streamline and taper values. This is
the same centerline-to-outline design popularized by Perfect Freehand; the
implementation is native Swift and does not copy third-party source.

Option-drag is rewet-only. Option-Shift-drag is fix-only and reuses Wash size
and Dry as fixation strength. Full-frame Fix, Unfix, Wet and Dry commands record
the authored camera's world rectangle when Master Record is enabled.

## Timeline semantics

The collapsible bottom timeline owns camera keyframes, gesture clips, material
events, and typed automation tracks. Addresses use project UUID plus stable
component/parameter identifiers, never labels or Swift key paths. Numeric,
point, and color values support Hold, Linear, Smooth and Cubic interpolation;
Boolean, enum and routing values hold. Camera interpolation follows the shortest
rotation path.

Scrubbing evaluates camera and automation but never rewinds raster ink. Playing
or painting earlier accumulates into the current artifact. **Replay to New
Canvas** explicitly clears and deterministically rebuilds recorded pen/wash
clips from fixed seeds. Local gesture properties continue to own their brush
values while global tracks own the environment.

## Clipboard and export

Copy publishes native timed SketchCam JSON, SVG, and Excalidraw-compatible
freehand JSON simultaneously. Paste checks native, Excalidraw, then SVG and
centers editable geometry in the current view. Imported geometry is marked with
estimated timing and remains vector-only until **Render as Ink**.

NRT still export accepts arbitrary pixel dimensions. It samples the best stored
tile LOD and redraws recorded vectors at target resolution without growing the
live simulation grid. Enlarging an unrecorded raster beyond its stored density
cannot invent detail; recorded curves remain resolution-independent.

## Current storage boundary

The sparse artifact currently stores composited pigment tiles. The manifest and
package directories are versioned for simulation checkpoints, but resuming
offscreen *live fluid state* (separate mobile pigment, fixed pigment, wetness,
velocity, and lock channels) requires a future checkpoint codec. Until then,
camera movement freezes the departing raster and starts a fresh bounded solver
over it. This is intentionally explicit so project files remain forward
migratable rather than pretending flattened pixels are reversible fluid state.
