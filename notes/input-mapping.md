# Input Mapping

Input Map is SketchCam's first camera-feature → system-event route. It is an
early, deliberately narrow slice of the larger mapping editor: select one hand
landmark to drive the macOS pointer and use thumb–index pinch as the primary
button.

## Current Behavior

- The visual picker exposes the 21 MediaPipe-style landmarks for each hand,
  labelled internally as `L0...L20` and `R0...R20`.
- The default pointer feature is right index tip (`R8`). Any displayed hand node
  can be selected.
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

## Pinch Signal And Safety

Pinch is the distance from thumb tip (`4`) to index tip (`8`), normalized by the
distance from wrist (`0`) to middle-finger MCP (`9`). The default close threshold
is `0.35`; release uses a `+0.10` hysteresis band to avoid rapidly alternating
mouse-down/up near the threshold.

If the selected feature disappears, a short `0.18 s` grace period tolerates a
single tracking dropout. A held primary button is then forcibly released and the
pointer filter resets. Disarming also emits a final mouse-up when needed.

System control requires Accessibility trust. The app never arms automatically.
Automated tests exercise the pure event state machine and never post real global
events.

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
4. Start with right index tip, **While pinching**, and the default thresholds.
5. Arm. Confirm open-hand movement leaves the physical mouse alone, a short pinch
   clicks, holding and moving drags, loss of the hand releases, and Disarm stops
   all mapped input.
6. Test **Always** only when continuous takeover is intended.

For later iterations, use `./script/build_and_run.sh` after code changes and
`./script/run.sh` when you only need to relaunch. The Arm button does not reopen
System Settings automatically; use Request access explicitly, then Refresh
after approving.

## Known First-Slice Limits

- One mapping and one primary-button gesture; no multi-route graph yet.
- Main display only; no display selector or virtual-desktop calibration.
- Hands only; the picker does not yet expose body/face feature groups.
- No secondary/right click, scroll, keyboard, pressure, dwell, zones, OSC,
  multitouch, or application-local drawing-event targets.
- Pinch always uses thumb/index on the selected feature's hand; gesture source
  and pointer source cannot yet be chosen independently.
- Live system-event behavior still requires a manual smoke test after signing and
  Accessibility approval.

The next architectural step is a collection of typed feature → event bindings
with explicit sources, transforms/gates, destinations, priority, and coexistence
policy. The current pointer engine should become one destination adapter rather
than the editor's entire data model.
