# Collage Workspace Checkpoint - 2026-07-02

Current branch: `codex/collage-workspace-v1`

## Summary

This checkpoint keeps the collage workspace direction but tightens the daily-use interaction details:
frames are easier to manage in the layer stack, paper is treated as its own editable frame, and ink no longer visually composites its selected surface input behind the stroke layer.

## Notable Changes

- Added `AGENTS.md` with the `atomic-human-in-the-loop` workflow hook for small manual-test-driven fixes.
- Moved Paper panel controls toward frame-local editing: tint and opacity now target the selected paper frame instead of the legacy global paper path.
- Removed Ink panel surface blend UI and stopped Ink from visually compositing its surface input; layer compositing is now the visible stacking mechanism.
- Kept explicit paper material-map routing in Ink, but disabled it unless the selected surface input is a Paper node.
- Added buffered numeric fields for sliders and frame transforms so partial float entry does not fight the cursor.
- Cleaned up the Layers/frame-stack row: compact add menu, icon-only role/blend controls, lock toggle, tighter spacing, and selected-frame-aware workspace hit testing with Cmd-click cycling through overlaps.
- Updated draw-tool and toolbar color-picker details: `scribble.variable` for Draw and stable RGBA color picking for the ink toolbar swatch.

## Manual Test Notes

- Verify Ink with `Surface input: None` renders over transparent/layer content without hidden paper compositing.
- Verify Paper tint/opacity affects the selected Paper frame only.
- Verify layer stack controls fit at the default panel width.
- Verify selecting a lower frame from Layers allows workspace dragging without the top frame stealing the drag; Cmd-click should cycle overlapping frames.
