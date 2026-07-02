# Newpaths Checkpoint - 2026-06-30

Branch: `newpaths`

## Recent Progress

- Restored path/ink undo around ordered `InkStrokeRecord` data while keeping legacy render paths as the Metal ink adapter.
- Split captured stroke data from rendered marks with Codable stroke samples, captures, render recipes, and records.
- Reworked panels into dockable/floating groups with default left/right/bottom placement and titlebar controls.
- Added layer drag-reorder, compacted layer rows, and made layer selection visible in the Layers panel.
- Recovered live output export from the drawing worktree: still, movie, GIF, and image-sequence output through `OutputStreamExporter`.
- Added `ExportConfiguration` plus core/app tests for export config and writer behavior.
- Added Escape/canvas-click focus clearing so focused text fields do not trap canvas shortcuts.

## Current Manual Test Points

- Export panel: choose destination, record a short movie, stop, and verify the output file opens.
- Focus handling: focus an export/layer text field, press Escape, then use canvas input or shortcuts.
- Layers panel: default dock width should show effects disclosure, eye, name, opacity, blend, and trash.
- Layer drag reorder should replace the removed up/down buttons.
- Dock resize flicker remains worth testing: the latest change computes resize deltas from global mouse position instead of local `DragGesture.translation`.

## Known Follow-Ups

- Proper recording preview and transport controls are still future work.
- Dock resize may still need a more structural fix if the visible divider continues to chase the dock edge.
- Presentation mode restore was previously imperfect after repeated Command-P toggles.

## UI Cleanup Checkpoint - 2026-07-02

- Promoted the old hover ink HUD into a dockable `Ink Toolbar` panel backed by persisted toolbar-control IDs.
- Kept top-docked toolbar panels single-row internally; toolbar tabs show icon-only labels with hover help.
- Main workspace toolbar is icon-first and omits Pen/Wash; ink-specific live controls live in the Ink Toolbar.
- Ink terminology now presents `Mark` / `Erase` instead of `Color` / `Dissolve` or raw black/white labels.
- Simplified the Ink panel by removing the embedded editor/action block; history/timeline remain separate panels.
- Tightened the frame stack row: visibility, output inclusion, editable name, role menu, blend menu, opacity, and delete are compact icon controls.
- Frame role and blend mode menus now open from icon-only controls; Preview no longer reuses the visibility-eye icon.
- Frame names can be renamed inline with Shift-click on the name label.
- The output-inclusion control is intentionally separate from visibility: visibility affects the artboard/workspace, while output inclusion affects published/exported viewport rendering.

## Local Run Helpers

- Build, install to `/Applications`, and run:
  `./script/build_and_run.sh`
- Run the newest local Debug build without rebuilding/installing:
  `./script/rundebug.sh`
- Debug the newest local Debug build:
  `./script/rundebug.sh --debug`
