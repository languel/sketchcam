# Presentation / transparent-overlay mode — plan

Goal: the app can become a transparent lecture overlay — only the drawn
content (doodle/effects on an alpha background) visible, window chrome and
side panel gone. Reference: github.com/languel/cloudywindow (Electron
version of the same idea; shortcut conventions borrowed below).

## Building blocks (macOS/SwiftUI specifics)

- The pipeline already produces alpha frames (Alpha background / ink-only).
  Presentation mode = render the preview onto a genuinely transparent
  NSWindow instead of the checkerboard.
- SwiftUI gives no direct NSWindow control → add a `WindowAccessor`
  (NSViewRepresentable) that hands the hosting NSWindow to a new
  `WindowModeController` owning all window state below.
- Transparent window: `isOpaque=false`, `backgroundColor=.clear`,
  `hasShadow=false`; preview view swaps checkerboard → clear.
- Decoration: toggle `styleMask` (.borderless ↔ titled set);
  `isMovableByWindowBackground=true` so the frameless window can be dragged
  (cloudywindow's invisible drag region equivalent).
- Always-on-top: `window.level = .floating` (or `.statusBar` over
  fullscreen apps + `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary]`).
- Click-through: `ignoresMouseEvents=true`. Once on, the window can't be
  clicked → control returns via a **menu bar extra (NSStatusItem /
  SwiftUI MenuBarExtra)** that mirrors the toggles and presets. MenuBarExtra
  is also the menu-bar home for all of this.
- Local keyboard shortcuts work while the app is focused; for click-through
  recovery rely on the menu bar extra (global hotkeys would need an event
  tap / accessibility permission — defer).

## Features → controls

| Feature | Mechanism | Shortcut (proposal, cloudywindow-style) |
|---|---|---|
| Toggle side panel | collapse controlsPane (keep action bar hidden too) | ⌘⌥U |
| Toggle window decoration | styleMask swap + movableByWindowBackground | ⌘⌥D |
| Transparent window | isOpaque/clear + hide checkerboard | ⌘⌥T |
| Always on top | window.level | ⌥⇧T |
| Click-through | ignoresMouseEvents (recover via menu bar extra) | ⌥⇧M |
| Fullscreen / fill screen | toggleFullScreen / setFrame(screen.frame) | ⌘⌥F |
| PIP placements | setFrame presets: corners ¼/⅙ size, bottom half, center overscan; cycle corners | ⇧F9–F12 or ⌘⌥arrows |
| Presentation mode (macro) | = panel off + borderless + transparent + on-top (+ optional click-through) | ⌘P or ⌘⌥Return |
| Flash border (find the window) | brief outline overlay | ⌘⌥B |

## Preset system

- `AppPreset: Codable` = ProcessingSettings + window mode struct
  (decoration/transparent/on-top/click-through/frame spec as
  screen-relative rect or named placement) + name.
- Store: JSON in UserDefaults (or Application Support file), ordered slots.
- Recall: ⌘1…⌘9; save current → slot via ⌘⇧1…9; preset matrix UI = grid of
  slot buttons in a new "Presets" row in the action bar or a popover; also
  listed in the MenuBarExtra.
- Requires Codable conformance on ProcessingSettings tree (plain structs —
  mechanical; RGBAColor/enums all Codable-friendly).
- Preset 0 = "Live default" (safe state: decorated, opaque, panel on) so
  there is always one keystroke back to normal.

## Implementation order (each step shippable)

1. WindowModeController + WindowAccessor; side panel toggle; decoration,
   transparent, on-top toggles; presentation-mode macro; menu commands via
   .commands { } (real menu bar).
2. MenuBarExtra mirroring toggles (needed before click-through ships).
3. Click-through + flash border.
4. Frame placements (fullscreen/fill/corner PIP, target display).
5. Codable settings + preset slots + matrix UI + shortcuts.

Open questions for later: per-display fullscreen choice; whether
presentation mode should auto-switch Background→Alpha and preview→full
window (probably yes: one macro that sets both pipeline + window).
