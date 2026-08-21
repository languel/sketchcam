# Portrait Drawing

Portrait is SketchCam's live, landmark-driven drawing algorithm for making a
semantic line portrait rather than a frame-by-frame proximity tangle. It is an
independent Drawing algorithm alongside Yarn, Wrap, and Line Walk.

Its central rule is: **the seed selects a route; incoming landmarks deform that
same route.** A changing expression or pose should move the drawing, not make
it suddenly choose a different set of connections.

This note describes the implementation as it exists today, including the parts
that are deliberately provisional and useful targets for artistic iteration.

## What goes in and what comes out

```text
Vision landmark groups + their graph edges
  -> connected semantic components
  -> face itinerary / body order / optional silhouette
  -> optional unified seeded route planner
  -> seeded sampling, orientation, and segmentation
  -> per-component stylization and inter-component bridges
  -> curve fitting
  -> variable-width ribbon strokes (CPU or Metal renderer)
```

The input is `MappedGroup`: a named landmark region, its point positions,
optional labels, and its semantic edges. Portrait does not invent a generic
nearest-neighbour tour over all points. It first separates the input into
meaningful components, such as an outer lip loop versus an inner lip loop.

The output is a small ordered list of routes by default:

1. Face route(s), including the optional crown/hair component.
2. One articulated body route when body landmarks are available.
3. An optional, separate body-outline route.

With **Unify face, body, and outline** enabled, those components instead share
one prepared source pool and one rendered stroke. The planner uses semantic
affinity plus a small endpoint-distance term to choose the next component, so a
face-to-body handoff remains part of the same pen gesture instead of becoming a
visibly disconnected overlay. A detail-priority bias gives eyes, nose, mouth,
and pupil marks higher value when choosing the expressive part of that
itinerary.

The routes are rendered as ribbons. Feature strokes use the selected ink width;
bridges can use a thinner relative width so the pen's travel reads as connective
tissue rather than equally important anatomy.

## Semantic decomposition

`PortraitPathBuilder.components` converts every graph-connected component in a
landmark group into an ordered `Component`:

- A component is marked open or closed from its edge degrees.
- Open components start at an endpoint when one exists.
- Closed components repeat their first point at the end.
- The edge walk is deterministic, so identical landmark topology and seed have
  identical ordering.
- Hand components retain `L`/`R` identity from landmark labels. This is
  anatomical handedness, not screen position, so a mirrored camera does not
  cause a left hand to attach to the right arm.

This is where exact landmark graph information is preserved. It is the right
place to improve anatomical semantics, split a region differently, or attach
new metadata to components.

## Current route planning

### Face

The canonical face order is:

```text
left brow -> left eye -> nose -> right eye -> right brow -> jaw -> mouth
```

For the mouth, up to two connected components are retained. This keeps inner
and outer lips available as an intentional pair rather than discarding one.

With Route variation at zero, Portrait uses that canonical order. Above zero,
a seeded PRNG selects one of six face-only templates, can omit some optional
brow/eye regions, and chooses where the crown enters. Nose, jaw, and mouth are
kept as anchors. This changes which long jumps occur without allowing the route
to leave the face.

The current templates are a curated list, not a general optimizer. They are
the main reason changing the seed changes the face's connection order today.

### Hair / crown

The optional crown is a synthetic, open component derived **only from face
landmarks**. Its local axis comes from the left/right brow or eye anchors; its
up direction is the perpendicular pointing away from the nose, mouth, and jaw.
It therefore follows face roll instead of staying horizontal in screen space,
and it cannot consume hand or body points. Clean mode draws a shallow scalp
contour; Wild mode makes a small, seeded boustrophedon weave through that cap,
so it fills a hair mass while remaining one component in the unicursal planner.

- Clean: a 9-point shallow scalp contour.
- Wild: a 19-point, three-row boustrophedon/Yarn-like scalp weave with seeded
  lateral and vertical texture.

The crown is inserted into the face itinerary near a brow/eye when possible.
It is therefore part of the same seeded unicursal shuffle, rather than a
separate decorative stroke.

### Body

The body order is currently fixed and anatomical:

```text
head -> left arm -> left hand -> torso -> right arm -> right hand
     -> right leg -> left leg
```

This is deliberately more conservative than the face planner. Its job is to
avoid the previous visually wrong hand-to-head or left-hand-to-right-arm jumps.
If no articulated body route is present, Portrait falls back to one body hull,
then one contour.

### Outline

Body outline is intentionally a *separate visual route inside Portrait* by
default, so it can sit underneath the face/body gesture while sharing Portrait's style,
sampling, curve fitting, width, and CPU/Metal renderer. It prefers, in order:

1. A tracked segmentation contour.
2. An explicit body hull.
3. A convex hull computed from face/body landmarks.

When Body outline is enabled, the app requests the Vision person contour for
Portrait automatically; Marks → Person does not need to be enabled separately.
The existing contour-detail control still determines how tightly that source
hugs concavities. For the hull fallback, a small synthetic scalp cap is added
if no head group is available; otherwise the silhouette tends to read as
jaw/skeleton only. The outline is rendered lighter and narrower than normal
Portrait strokes.

It is not yet a semantically modelled body boundary. A convex hull is cheap and
stable, but it loses concavities and can make a poor outline in expressive
poses. This is an obvious future replacement point.

When the unified route is enabled, the outline is no longer rendered as an
independent route. It participates in the same seeded itinerary, with a small
silhouette penalty so detailed facial features are normally preferred for
nearby handoffs.

## Seeded variation

Portrait uses a tiny deterministic PRNG. The same seed plus the same landmark
topology produces the same route decisions, so live motion stays coherent.

The seed influences:

- face-itinerary template;
- optional face-region omission at higher Route variation;
- seeded nose interior selection and isolated pupil-ring promotion;
- crown insertion point;
- which landmark samples survive inside a component;
- open-component reversal;
- closed-loop starting point;
- segment-cut tie breaking;
- bridge bend direction;
- organic drift and embellishments.

`Route variation` controls topology-related choices in the separate face route.
At zero, points preserve
detector order (apart from normal bounding); at higher values, fewer points may
be selected, open chains may reverse, closed loops may rotate, and the face
template changes. `Organic variation` only adds small, repeatable normal
offsets to the chosen geometry; it does not select a different itinerary.

In unified mode, `Detail priority` (0–1) adds a semantic weight to eyes, nose,
mouth, and pupil marks. At zero, geometric travel and the face itinerary
dominate. Higher values pull those detail regions earlier in the shared route
while preserving the same seed and deterministic output. Unified mode keeps
topology variation at zero while live landmarks move; changing the seed is the
intentional way to choose another topology.

`Subsample` is an explicit percentage of source points retained by the route.
It is deterministic for a given seed, preserves open endpoints and detail
anchors, and is independent of live topology variation. This makes it safe to
explore simpler or more fragmentary portraits without introducing frame-to-
frame route rewiring.

### Landmark sampling

For an open component, the two endpoints are always retained; sampled interior
points may be omitted and the entire chain may reverse. For a closed component,
a sampled subset is rotated to choose a different pen entry point, then closed
again. This is how a lip, eye, or nose can hand off at different locations
without turning into unrelated random geometry.

## Segments and bridges

`Segments` is currently 1–6 and applies to the face itinerary.

- **1** means one planned face route, with bridges between features.
- Higher values add breaks only at semantic boundaries.
- Boundaries inside the same region are not legal cuts, so inner/outer lips
  stay together where possible.

Legal cuts are ranked by low semantic affinity plus a small seeded jitter.
Current high-affinity pairs include brow-eye, nose-eye/brow, mouth-jaw, and
crown-neighbour; unrelated parts are lower affinity and are more likely to be
separated.

When two consecutive components are in the same landmark region, their bridge
uses full width. A bridge across regions uses `Connector width` (0.12–1.0)
times the normal width and slightly reduced width variation. This makes a
mouth's two loops feel like one pen gesture while a jump from eye to nose can
be visually quieter.

## Stylization

Each sampled component is independently transformed before bridges are added.
The source landmarks remain the reference; stylization does not change semantic
component membership.

| Style | Geometry hand | Bridge hand |
| --- | --- | --- |
| Fluid | two smoothing passes | one gentle normal-offset midpoint |
| Cubist | interpolates between 5 open / 7 closed anchors | one axis-aligned elbow |
| Ornate | normal-direction wave | three-point looping bridge |

`Follow markers` blends source geometry toward the style geometry. Even at full
Follow, 15% of the artistic hand remains, so Fluid/Cubist/Ornate do not become
identical. `Flourish` controls both ornate wave/bridge amplitude and the rate
of inserted local loops. `Organic variation` then introduces gentle normal
noise while keeping open endpoints fixed.

After stylization, Fluid and Ornate use Hobby curve fitting; Cubist uses a
polyline. Each resulting path is converted through the shared variable-width
ribbon system, with optional halo.

## Live update and performance rules

There is no persistent canonical face model yet. “Continuous morphing” means
that, while the enabled landmark regions and seed are unchanged, the same
semantic itinerary is rebuilt deterministically against new point positions.
The topology therefore stays stable as the performer moves.

The implementation protects the real-time path in three ways:

- Dense segmentation contour input is ignored when an articulated body route
  exists; it is only a silhouette fallback.
- A full route is capped at 320 points; each render stroke is capped at 160.
- Rendering uses the shared ribbon tessellator and can stay on the Metal path.

These limits preserve endpoints and order through uniform sampling, rather than
changing the semantic itinerary to solve a performance problem.

## Controls and defaults

| Control | Default | Current meaning |
| --- | ---: | --- |
| Style | Fluid | Fluid, Cubist, or Ornate drawing hand |
| Follow markers | 0.72 | Likeness versus stylization |
| Flourish | 0.20 | Loops, bridge amplitude, ornament density |
| Organic variation | 0.22 | Seeded local hand-drawn drift |
| Seed | 7 | All deterministic artistic choices |
| Route variation | 0.38 | Itinerary, sampling, orientation, loop entry |
| Segments | 1 | Number of face routes, 1–6 |
| Connector width | 0.42 | Relative width for cross-part bridges |
| Unify face, body, and outline | off | One seeded planner for face, body, and optional silhouette |
| Detail priority | 0.65 | Bias the unified planner toward eyes, nose, and mouth |
| Subsample | 1.0 | Percentage of source points retained by the seeded sampler |
| Body outline | off | Integrated line-based contour/hull silhouette; requests Person contour when enabled |
| Outline weight | 0.68 | Outline opacity |
| Top-of-head line | off | Add face-derived crown |
| Hair | Clean | Clean or Wild crown geometry |
| Hair amount | 0.45 | Crown lift/wiggle amount |
| Width | 2.8 | Main ribbon width |
| Width variation | 0.45 | Calligraphic taper/swell |
| Halo | off | Glow behind ribbons |

All values live in `LandmarkSettings`, are Codable, and use optional fields plus
resolved defaults for compatibility with presets made before Portrait existed.

## What is intentionally unfinished

The current system is a strong first scaffold, not the final portrait language.
The key limitations to keep in mind when evaluating output are:

- Face planning is template-based, so it cannot yet search a broader space of
  semantically valid single-line drawings.
- Feature entry and exit points are sampled/rotated, but not optimized for pen
  economy, visual balance, or a specific drawing vocabulary.
- The body is an ordered skeleton route rather than a body-aware contour or a
  designed gesture line.
- The hull outline is semantically weak for arms, shoulders, and occlusion.
- Hair follows face roll through a brow/eye-derived local coordinate frame, but
  it is still an expressive arch rather than a fitted scalp contour or a full
  3D head-pose model.
- The default mode keeps face, body, and outline as separate routes. Unified
  mode is the single rendered-stroke alternative, but its semantic order still
  needs more authored pose/occlusion knowledge for every expressive pose.
- Multiple people are not assigned persistent portrait identities.

## Productive directions for the next iteration

When proposing changes, it is useful to name which stage should own them:

| Desired change | Best ownership point |
| --- | --- |
| “Nose should naturally flow into brow” | Face itinerary templates, or a future scored route planner |
| “Mouth loops should sometimes be one gesture” | Component grouping and bridge/entry-exit selection |
| “Different seed should make a genuinely new drawing” | Route planner, sampling policy, and segment partitioning |
| “Do not attach hand to head” | Region/component constraints and body order |
| “A better silhouette / shoulders / scalp” | Outline generator, replacing convex-hull fallback |
| “Hair should respond to yaw/pitch or fit the scalp” | Crown generator, adding a scalp contour and full 3D head pose |
| “Make it look more cubist / ornate” | Style transform and bridge grammar |
| “Make it more like the performer” | Follow policy, face/body canonical templates, temporal model |
| “Make it feel like one pen drawing” | Global planner across face/body segments and transition costs |

The most promising architectural next step is probably a **semantic route graph**:
each feature would expose several meaningful entry/exit ports, edges would have
costs for anatomical affinity, distance, crossing, and style preference, and a
seed would choose among high-quality tours rather than among a small fixed list.
That would preserve live determinism while opening the design space needed for
elegant nostril → bridge → brow and mouth → jaw → cheek-like lines.

## Code map

- `SketchCam/Landmarks/Drawing/PortraitDrawing.swift` — all component
  extraction, planning, seeded variation, stylization, and PRNG logic.
- `SketchCamCore/Sources/ProcessingSettings.swift` — Portrait controls,
  defaults, Codable compatibility.
- `SketchCam/App/ContentView.swift` — Portrait control panel.
- `Tests/SketchCamAppTests/PortraitDrawingTests.swift` — semantic, stability,
  and performance tests.

The historical implementation checkpoint is
[`notes/portrait-presentation-checkpoint-2026-08-12.md`](../notes/portrait-presentation-checkpoint-2026-08-12.md).
