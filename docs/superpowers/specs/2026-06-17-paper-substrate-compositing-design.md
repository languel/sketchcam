# Paper Substrate Compositing Design

## Goal

Make the expanded procedural paper controls easier to manage, improve paper color shaping, and allow Ink's cached procedural paper to blend with a routed substrate instead of being disabled whenever a source is selected.

## Ink panel

The complete procedural-paper editor moves into a collapsed `DisclosureGroup`. The Paper enable toggle, substrate input menu, overall substrate opacity, and blend mode remain visible above it so the common controls stay accessible.

When the Ink texture input is routed to another pixel source, the cached procedural paper is combined with that source before ink pigment is composited. The selectable substrate-paper modes are:

- None
- Normal
- Multiply
- Screen
- Add
- Overlay
- Darken
- Lighten
- Difference
- Subtract
- Soft Light

Multiply is the default for a routed source. None bypasses procedural paper and uses the routed source directly. With no routed source, Ink uses its procedural paper normally and the blend selector has no effect.

The existing Paper enable toggle remains authoritative. Turning Paper off produces transparent ink-only output and bypasses both routed and internal substrate display.

## Blend model

Add `softLight` to the shared `BlendMode` enum and Metal/Core Image compositing implementations so it is available in ordinary layer blend menus. None is not added to `BlendMode`; it is an Ink-specific substrate option because ordinary layers already have visibility controls.

Add a small persisted Ink substrate blend enum containing `none` plus the shared modes. Existing presets decode to Multiply when a routed source is present and preserve the current internal-paper behavior when no source is routed.

The substrate mixer runs after the cached procedural paper is generated and before ink pigment display. It must reuse existing materialized GPU/CI composition paths and must not regenerate the paper texture solely because the routed source changes frame content.

## Paper color controls

Add `saturation` to `PaperConfig`, resolved configuration, cache keys, shader parameters, and both paper editors. Default saturation is 1. The UI range is 0 through 2.

Increase the Contrast UI range from 0 through 2 to 0 through 4.

Replace contrast around fixed mid-gray:

```text
(paper - 0.5) * contrast + 0.5
```

with contrast around the configured tint:

```text
tint + (paper - tint) * contrast
```

This amplifies procedural variation without pushing pale paper uniformly toward clipped white. Saturation is applied after contrast by mixing paper RGB with its luminance:

```text
mix(luminance(paper), paper, saturation)
```

Final RGB remains clamped to the renderable range.

## Performance

- Paper remains cached by resolved configuration and dimensions.
- Contrast and saturation participate in the cache key and cause one regeneration when edited.
- Animated routed sources do not invalidate the procedural-paper cache.
- Substrate composition adds one blend pass only when a routed source and a paper blend other than None are active.

## Compatibility

- Missing Paper saturation decodes to 1.
- Missing Ink substrate blend decodes to Multiply for routed substrates.
- Current standalone Paper nodes retain their other resolved values.
- Current internal Ink paper remains visually unchanged at Contrast 1 and Saturation 1.

## Validation

- Contrast above 1 increases visible fiber/tooth/grain variation without raising the average pale tint toward white.
- Saturation 0 produces grayscale paper; 1 preserves the configured tint; 2 exaggerates chroma without invalid values.
- Every substrate mode produces the expected routed-source/paper combination.
- None matches the routed source without procedural paper.
- Soft Light appears and works in ordinary layer blend menus.
- Collapsing Paper settings leaves common Ink substrate controls visible.
- A stable paper configuration does not regenerate while a routed movie or camera source updates.
