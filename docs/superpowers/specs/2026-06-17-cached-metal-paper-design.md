# Cached Metal Paper Design

## Goal

Replace the two current paper implementations with one reusable procedural Metal paper renderer. The renderer must reproduce the existing internal Ink paper exactly with its default configuration, support independent Paper source nodes in the layer stack, and avoid per-frame regeneration.

## Product behavior

- Ink keeps an internal paper substrate enabled by default.
- Paper remains available as a standalone source beside Camera, Movie, Solid, Drawing, Ink, and Web.
- Every Paper source owns an independent configuration, so a stack may contain multiple visually distinct papers.
- Ink's internal paper owns a separate configuration with the same controls and defaults as a new Paper source.
- The existing internal Metal paper appearance is the canonical default. Existing projects and new default configurations must reproduce it.
- The existing Core Image Fiber, Speckle, and Wash generator is retired. Preset labels are not required; variation comes from continuous controls.

## Paper configuration

The shared configuration contains:

- tint and opacity
- contrast
- fiber strength, X scale, Y scale, and orientation
- tooth strength, X scale, and Y scale
- grain strength, X scale, and Y scale
- seed
- vignette strength

Defaults are derived from the constants currently embedded in `ink_display`, including the warm base color, fiber/tooth/grain frequencies, modulation strengths, and vignette. Parameters use bounded UI sliders, while numeric fields may accept safe experimental values outside the slider range where the existing control pattern supports it.

## Architecture

### Shared renderer

Introduce a focused Metal paper renderer that outputs a materialized paper texture from a `PaperConfig` and output size. Move the existing paper noise functions and paper-color calculation out of the ink display kernel into a dedicated paper-generation kernel.

The cache key includes:

- complete `PaperConfig`
- output width and height
- output pixel format when relevant

The renderer regenerates only when this key changes. Normal frame rendering reuses the cached materialized texture.

### Ink integration

The ink engine continues to simulate pigment, wetness, and velocity independently of paper. Its display pass samples the cached internal paper texture as the substrate and applies pigment absorption, coverage, wet tint, and opacity over it.

Paper remains visual rather than a simulation obstacle: fiber and tooth do not alter velocity, wetness, or diffusion in this scope. This preserves the current ink behavior while adding paper variety.

### Layer-graph integration

Each `.paper(PaperConfig)` source requests an image from the same cached Metal renderer. Multiple Paper nodes remain independent because each node carries its own configuration and therefore its own cache key/result.

Routing a Paper source into Ink's texture input continues to replace the internal substrate visually. The routed source and Ink's internal paper use the same renderer, so equivalent configurations produce equivalent pixels.

### Compatibility

Extend `PaperConfig` with optional or decode-defaulted fields so existing saved graphs remain loadable. Legacy Fiber, Speckle, and Wash values map deterministically to reasonable shared-renderer configurations during decoding or normalization. Existing Ink settings map to the canonical default paper configuration.

## User interface

### Layer stack

Move `+ Add layer` and its dropdown to the header row immediately after `LAYER STACK`. Remove the bottom placement.

Expanded Paper source controls expose the shared configuration in compact groups for Base, Fiber, Tooth, and Grain. X/Y scale controls remain separate. Orientation applies to the fiber coordinates before anisotropic scaling.

### Ink panel

The Paper section exposes the identical configuration for Ink's internal substrate. Controls are disabled when a routed texture replaces the internal substrate, matching current routed-input behavior.

## Performance

- Paper generation never runs every frame when configuration and output size are unchanged.
- Cache invalidation is explicit and limited to paper configuration, resolution, and format changes.
- Each distinct active Paper node may own one cached texture; unused nodes do not regenerate.
- The implementation avoids recursive Core Image graphs and preserves the existing materialized-frame approach.
- The noise kernel uses a small fixed octave count equivalent to the current shader; no unbounded loops or dynamic texture allocations occur per frame.

## Validation

- Golden-image or pixel-tolerance test: default shared renderer matches the current internal Metal paper at representative resolutions.
- Configuration tests: changing each parameter invalidates the cache and changes output; unchanged configuration reuses it.
- Compatibility tests: old Paper node payloads and old Ink settings decode to valid defaults.
- Integration test: two Paper nodes with different seeds/settings render independently.
- Ink comparison: internal paper and a routed Paper node with identical settings produce matching substrates.
- UI verification: Add Layer appears beside `LAYER STACK`, and Paper controls remain usable at narrow panel widths.
- Performance check: stable paper configurations cause no paper regeneration during a sustained preview run.

## Out of scope

- Paper fibers influencing fluid velocity, wetness, diffusion, or drying.
- Imported photographic paper textures.
- Animated paper noise.
- A global paper configuration shared by all nodes.
