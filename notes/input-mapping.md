# Input Mapping

Input Map maps live hand motion to either the SketchCam canvas or macOS system
events. The original one-feature pointer mode remains available; the gesture
editor adds a small set of natural hand actions.

## Current Behavior

- The visual picker exposes the 21 MediaPipe-style landmarks for each hand,
  labelled internally as `L0...L20` and `R0...R20`.
- The default pointer feature is right index tip (`R8`). Any displayed hand node
  can be selected.
- Computer destination can continuously move the pointer, or use the
  **While gesturing** drive mode to move only while a recognized gesture is
  active. The older **While pinching** behavior remains when gesture rules are
  not enabled.
- **While pinching** emits no pointer movement while the hand is open. Closing
  the pinch moves to the selected feature and presses; movement while held emits
  a drag; opening releases.
- **Always** continuously maps the selected feature to the main display. Pinch
  can still control the primary button, but the mapped pointer may compete with
  a physical mouse or trackpad.
- Camera width/height crop the useful normalized tracking region before mapping
  it across the main display. Smoothing is exponential and acts in screen space.
- The mapping is saved in UserDefaults. The armed state is intentionally not
  saved and must be explicitly enabled each app launch.

## Gesture Actions

Choose **Canvas** or **Computer** in the Motion Control panel. The built-in
Canvas rules map pinch to draw and fist to dissolve/wash in the active visible
Ink frame (or the first visible Ink frame); if there is no Ink layer, arming
creates one. If Ink layers exist but are all hidden, the panel asks you to show
one. Open palm is unassigned. Canvas actions use the camera region
mapped across the Ink frame and do not post mouse or keyboard events. The
gesture stroke is committed to the existing canvas action history when it
ends.

The Computer preset maps the selected hand landmark continuously to the main
display, pinch to held primary click/drag, and fist to a right click. Set the
drive mode to **While gesturing** to leave the physical mouse alone outside a
recognized action. Rules can be edited: pinch, fist, or open palm can do
nothing, draw/erase (Canvas), click/drag, right click, scroll, send a listed
key/shortcut, or disarm (Computer). Discrete key and right-click actions fire
once at gesture entry; draw, erase, drag, and scroll remain active while held.
The keyboard list currently contains navigation keys, Space/Enter/Tab/Escape,
Undo, and Redo; this is not free-form typing or full keyboard emulation.

Recognition uses normalized hand-joint distances, confidence gating, release
hysteresis, and a configurable dwell before activation. A selected landmark or
hand lost past the grace period releases held actions. A camera-frame watchdog
disarms if frame updates stop. Escape disarms; mappings persist, armed state
does not. Computer actions require Accessibility trust; Canvas does not.
Editing a rule or switching destinations disarms first so a held action is
released before the new mapping takes effect.

## Pinch Signal And Safety

Pinch is the distance from thumb tip (`4`) to index tip (`8`), normalized by the
distance from wrist (`0`) to middle-finger MCP (`9`). The default close threshold
is `0.35`; release uses a `+0.10` hysteresis band to avoid rapidly alternating
mouse-down/up near the threshold.

If the selected feature disappears, a short `0.18 s` grace period tolerates a
single tracking dropout. A held primary button is then forcibly released and the
pointer filter resets. Disarming also emits a final mouse-up when needed.

System control requires Accessibility trust. The app never arms automatically.
Automated tests exercise the pure event state machines and never post real
global events.

## Runtime Boundary

`SystemPointerEngine` is a pure state machine responsible for semantic lookup,
coordinate remapping, smoothing, pinch hysteresis, and mouse lifecycle events.
`SystemPointerController` is the narrow imperative boundary that checks
Accessibility and posts `CGEvent`s. `SystemInputMappingPanel` owns the SwiftUI
editor and homunculus-style hand map.

Input Map has a dedicated camera-backed hand detector. It does not depend on the
Marks toggle, does not use the synthetic landmark source, and does not change
which face/body/hand regions Drawing tracks.

## Local Test Sequence

1. Run `./script/build_and_run.sh` once. It installs and launches the stable
   `/Applications/SketchCam.app` bundle.
2. Approve `/Applications/SketchCam.app` under **Privacy & Security →
   Accessibility**. Normal source rebuilds keep the same signed identity, so
   the grant should persist. Use `./script/run.sh --permissions` to reopen the
   correct pane without rebuilding.
3. Open **View → Show Tabs → Input Map**.
4. For system control, choose **Computer**, select right index tip, and start in
   **While gesturing** mode. Approve the explicit Accessibility prompt before
   arming.
5. For drawing, choose **Canvas**, show/select a visible Ink frame, and arm.
   Pinch draws; fist washes/dissolves; opening the hand ends the stroke.
6. Confirm tracking loss and Escape release/disarm. Test **Always** only when
   continuous pointer takeover is intended.

For later iterations, use `./script/build_and_run.sh` after code changes and
`./script/run.sh` when you only need to relaunch. The Arm button does not reopen
System Settings automatically; use Request access explicitly, then Refresh
after approving.

## Known First-Slice Limits

- One selected pointer landmark, one selected hand, and three built-in gesture
  classes; no multi-hand priority graph or independently selected gesture hand
  yet.
- Main display only; no display selector or virtual-desktop calibration.
- Hands only; the picker does not yet expose body/face feature groups.
- Keyboard actions are a short fixed list; no arbitrary text entry, zones,
  pressure, OSC, multitouch, or configurable desktop/display calibration.
- Pinch always uses thumb/index on the selected feature's hand; gesture source
  and pointer source cannot yet be chosen independently.
- Live system-event behavior still requires a manual smoke test after signing and
  Accessibility approval.

The next architectural step is a collection of typed feature → event bindings
with explicit sources, transforms/gates, destinations, priority, and coexistence
policy. The current pointer engine should become one destination adapter rather
than the editor's entire data model.
