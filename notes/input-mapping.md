# Input Mapping

Input Map maps live hand motion to either the SketchCam canvas or macOS system
events. The original one-feature pointer mode remains available; the gesture
editor adds a small set of natural hand actions.

Canvas also has a **Custom map stack**. Enable it to start with editable
left-pinch pen draw, right-pinch wash draw, right-fist wash erase, and left-fist
pen erase actions, plus a passive left pinky-tip/thumb-tip distance control for
wash size while the right hand pinches. Add, rename, reorder, disable, or remove
maps independently. The first matching active action owns the stroke; later
matching passive controls can override pen size, wash size, flow, or brush ink.
Active actions and passive controls may observe different hands. Distance on
one hand is divided by its palm length; cross-hand distance uses normalized
camera coordinates. Three-joint angles are degrees. Input and output ranges
are editable, including reversed output ranges. Changes release any active
stroke and require re-arming.
Parameter changes during a stroke are captured as short adjoining Ink segments
when the value moves enough to affect the rendered mark; each segment keeps its
own recorded brush settings. The selected homunculus landmark supplies the
pointer position for both hands in the custom stack.

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
6. To try custom painting, disarm, enable **Custom map stack**, then arm again.
   Pinch-drag left for pen, pinch-drag right for wash, and fist-drag either hand
   for its corresponding erase action. While right-pinch painting, open or close
   the left pinky/thumb span to vary wash size. Reordering maps changes which
   active rule wins when both hands match at once.
7. Confirm tracking loss and Escape release/disarm. Test **Always** only when
   continuous pointer takeover is intended.

For later iterations, use `./script/build_and_run.sh` after code changes and
`./script/run.sh` when you only need to relaunch. The Arm button does not reopen
System Settings automatically; use Request access explicitly, then Refresh
after approving.

## Current Limits

- The custom Canvas stack supports either hand and arbitrary ordered maps, but
  only one active paint stroke owns the live Ink channel at a time. A second
  hand may modulate it passively; simultaneous two-handed drawing is deferred.
- Gesture classes are still pinch, fist, and open palm. Joint measurements can
  use any of the 21 tracked joints on either hand.
- Main display only; no display selector or virtual-desktop calibration.
- Hands only; the picker does not yet expose body/face feature groups.
- Keyboard actions are a short fixed list; no arbitrary text entry, zones,
  pressure, OSC, multitouch, or configurable desktop/display calibration.
- Pinch recognition always uses thumb/index on its action hand. All active
  custom maps share the selected pointer landmark index; per-map pointer
  landmarks are not yet exposed.
- Live system-event behavior still requires a manual smoke test after signing and
  Accessibility approval.

The custom stack is currently a Canvas painting adapter. The Computer preset
still uses the original fixed-action editor; generic desktop destinations,
arbitrary expression trees, and simultaneous live strokes remain future work.
