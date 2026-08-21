# Portrait Drawing And Presentation Output Checkpoint — 2026-08-12

Branch: `feat-drawing`

## Shipped In This Checkpoint

### Portrait drawing algorithm

- Added Portrait beside Yarn, Wrap, and Line Walk as an independently enabled
  drawing algorithm.
- Builds deterministic semantic face and body routes from enabled landmark
  regions. Compound regions such as outer and inner lips are split into stable
  connected components before route construction.
- Live landmark updates deform a route with stable topology. This avoids the
  visible rewiring and tangled crossings caused by re-solving a proximity tour
  on every frame.
- Added three artistic hands:
  - **Fluid** smooths the source route into a gestural continuous line.
  - **Cubist** favors polygonal segments and angular bridges.
  - **Ornate** adds wave deformation, loops, and more elaborate connectors.
- Added controls for **Follow markers**, **Flourish**, ink color, width,
  calligraphic nib variation, halo, and a deterministic **Seed**.
- Added **Organic variation**: a seeded, low-amplitude normal drift that keeps
  landmarks attached while allowing repeatable hand-drawn asymmetry. Shuffle
  changes the look without changing the selected route for that seed.
- Added **Route variation**: the same seed now also chooses among face-only
  semantic itineraries, samples a stable subset of landmarks, reverses selected
  open chains, and rotates closed features. The selection is stable between
  detections, so live motion still morphs instead of rewiring every frame.
- Added an opt-in **Top-of-head line** with Clean and Wild hair styles. This
  extrapolation uses a face-local brow/eye frame, follows head roll, and cannot
  connect hands or body joints; it participates in the seeded face itinerary
  instead of being rendered as a disconnected extra route. Wild uses a compact
  Yarn-like scalp weave rather than a tall cone-shaped arch.
- Added **Segments** (1–6) to split the face itinerary at seeded semantic
  boundaries. Same-region components such as inner/outer lips remain grouped
  when possible. Added **Connector width** so cross-part bridges can be thinner
  than the feature strokes while same-part links retain the main width.
- Added an opt-in **Body outline** route. Portrait automatically requests the
  tracked segmentation contour when this toggle is enabled, then prefers that
  contour over an explicit hull and finally a cheap convex hull from current
  face/body landmarks. The line-based silhouette is a separate, lighter route
  inside Portrait, using the same seeded sampling, curve fitting, style, width,
  and CPU/Metal renderer as the rest of the drawing.
- Added an opt-in **Unify face, body, and outline** route planner. Face,
  articulated body, and the optional silhouette now share one seeded itinerary
  when enabled, with endpoint-aware handoffs that keep the line connected.
  **Detail priority** biases that planner toward eyes, nose, and mouth without
  changing the deterministic seed model. The existing separate-route mode
  remains the default.
- Unified mode now renders its prepared face/body/outline pool as one stroke,
  keeps topology fixed while live landmarks move, and uses editable Seed plus
  **Subsample** for intentional variation. Isolated pupil points are promoted
  to small eye marks and nose interiors receive a seeded selection variant.
- Uses the existing shared CPU/Metal ribbon stroke path and persists its settings
  without breaking presets written before Portrait existed.

### Presentation destination

- Added a presenter toggle to every workspace frame, using
  `person.crop.rectangle` / `.fill` independently from the program-output toggle.
- Added **Presentation** as the default secondary Output-window source.
- Program and Presentation share the graph and compositor but filter frames with
  separate `includeInOutput` and `includeInPresentation` flags.
- Old workspace frames inherit their previous program inclusion for presentation
  when decoded.

## Verification

- `xcodegen generate`
- Full unsigned macOS `SketchCam` test scheme passed.
- Focused Portrait geometry and LayerGraph compatibility suites passed after the
  final documentation-adjacent cleanup.
- `git diff --check` passed.

The local Xcode installation reports an out-of-date CoreSimulator framework,
but macOS test execution completes successfully; no simulator is used here.

## Manual Live Test

1. Enable Marks and the face/body regions that should contribute.
2. Open Portrait, enable it, and temporarily disable Yarn, Wrap, and Line Walk
   to inspect Portrait alone.
3. Start with Follow `0.72` and Flourish `0.20`.
4. Move through expressions and body poses, then compare Fluid, Cubist, and
   Ornate. Increase Follow for likeness; reduce it for stronger idealization.
   Use Seed/Shuffle and Organic variation to compare repeatable drawing looks.
   Enable Body outline to add a line-based scalp-and-shoulder silhouette. The
   Portrait toggle requests the Person contour automatically; Marks → Contour
   remains the place to tune its detail.
5. In Layers, make at least one frame presenter-only and another program-only.
   Open Output with source Presentation and confirm each destination contains
   only its selected frames.

## Known First-Slice Limits / Next Work

- The default mode still renders face, body, and outline as separate continuous
  routes. Unified mode is the experimental single-pen alternative and may need
  more semantic affinity tuning for expressive poses.
- The semantic itinerary remains intentionally stylized. Live tuning should
  refine the semantic affinity scores, segment selection, crown placement, and
  the amount of characteristic asymmetry in each style.
- Multiple detected people are not yet assigned independent portrait identities;
  this first slice is aimed at one presenter.
- Artistic styles currently deform live landmark geometry directly. A later
  model can add authored canonical templates, temporal response/lag, and
  style-specific parameters beyond the shared Follow and Flourish controls.
- Presentation is a second full composite, not yet a dedicated borderless PiP
  companion with its own camera/presenter layout presets.
