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
  calligraphic nib variation, and halo.
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
5. In Layers, make at least one frame presenter-only and another program-only.
   Open Output with source Presentation and confirm each destination contains
   only its selected frames.

## Known First-Slice Limits / Next Work

- Face and body are separate continuous routes rather than one literal
  pen-down path across the whole person.
- The semantic itinerary and connectors are intentionally simple. Live tuning
  should refine which features are visited, connector placement, and the amount
  of characteristic asymmetry in each style.
- Multiple detected people are not yet assigned independent portrait identities;
  this first slice is aimed at one presenter.
- Artistic styles currently deform live landmark geometry directly. A later
  model can add authored canonical templates, temporal response/lag, and
  style-specific parameters beyond the shared Follow and Flourish controls.
- Presentation is a second full composite, not yet a dedicated borderless PiP
  companion with its own camera/presenter layout presets.
