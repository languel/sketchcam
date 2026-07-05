# SketchCam UI Guidelines

## Panel Density

- Keep panel content close to the title row. The first control or subsection should feel attached to the panel header, not separated by a large blank band.
- Prefer compact disclosure sections for groups of related controls. Collapsed subsections should stack with minimal vertical gaps.
- Expanded parameter rows should use stable label and value-field widths so sliders line up across a section.
- Use the current Layers and Ink panels as the reference for density, spacing, and control ordering.

## Panel Structure

- Put the most-used controls first and expanded by default. Secondary routing, response, path, advanced, or diagnostic controls should usually be collapsed.
- Use short subsection titles: examples include `Brush properties`, `Inputs`, `Response`, and `Path`.
- Keep controls in the panel as the detailed editor view. Performance/live controls can also be exposed as compact toolbar controls when useful.

## Layer And Frame Rows

- Frame rows should stay icon-first and compact: disclosure, visibility, output inclusion, editable name, role, blend, opacity, lock, and delete.
- Avoid text dropdowns in dense rows when an icon menu communicates the same action.
- Keep per-row tooltips specific to the hovered control.

## Ink Controls

- Ink panel settings should edit the selected ink frame. The panel is a view into frame-local properties, not a global singleton editor.
- Ink Toolbar controls should be small, visual, and suitable for live use. Dials should show `label: value` while hovered or scrubbed.
- Ink and Wash color pickers are separate toolbar controls.
