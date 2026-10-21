# Motion sequences and local MCP commands

Input Map → Canvas → Custom map stack now accepts **Tool sequence** rules alongside
painting actions and passive parameter maps. A sequence is an ordered list of
held poses (pinch, fist, open palm), extended-finger counts, counted fist
squeezes, proximity tests, and three-point angle tests between tracked hand
joints and face points. Each held step has a hold time and maximum gap; a
squeeze step counts a closed-fist transition after the hand opens again, within
its configured time window. A completed
sequence invokes the selected SketchCam command once; its final condition must
release before it can fire again. Loss of tracking cancels partial progress.

Active and passive maps can include finger-count conditions for either hand.
Select **Any gesture**, a count, and optionally **Other hand count** to map a
two-hand sign that is not classified as a pinch, fist, or open palm. A sequence
can also hold one or both hands in a finger-count pose, then wait for a gesture
change (for example, left hand three-finger sign → left open palm → pick color).
For more specific signs, set each digit to **Any**, **Up**, or **Folded**; for
example, index Up + middle Up + ring Folded + little Folded distinguishes a
peace sign from other two-finger poses.
Passive maps can use one hand's pose as the gate while measuring another hand's
joints continuously, such as left fist → right thumb/index distance → wash size.
Finger counts are estimated from 2D fingertip and palm geometry; occluded or
low-confidence joints make the count unavailable rather than guessing. The
current Vision input is 2D, so it does not provide a dependable
palm-versus-back-of-hand label. Use finger signs or squeeze sequences when that
distinction matters.

For example, add a **Fist squeezes** step for the left hand, set **Squeezes** to
2 and **Within** to 0.8 seconds, then choose any registered app command. A
single fist close in the Computer mapping remains a click; closing and reopening
repeatedly can therefore be used as click-like input as well.

For example, **Add tool sequence** defaults to left little fingertip near the
nose, which picks the live camera color at the nose into the active Ink color.
Face detection is requested by
Input Map only while an armed rule needs a face point. The distance threshold
is measured in normalized camera-image coordinates; start around 0.045 and
adjust for the framing. Tool sequences currently run with the Canvas custom
map stack, and the command picker includes registered shortcut commands.
Editing a map finishes any current stroke or held mouse action and resets
recognition, while keeping motion control armed. Switching Canvas/Computer
destination still disarms, so the new destination must be explicitly armed.

Input Map and Gesture Cues share an **Arm / Disarm** control. The default
app-wide shortcut is **Control–Option–A**, customizable in Keys; Escape still
disarms. The command `motion.arm.toggle` is also available to tool sequences
and MCP through the same command catalog.

Enable **Two palms to arm / disarm** in either panel for hands-free control.
Hold both open palms for 0.9 seconds, then close either hand with both hands
visible for at least 0.3 seconds before repeating. The pose is reserved while
enabled, so ordinary open-palm actions do not fire during it. This option
keeps hand tracking active while disarmed; other gesture maps remain inactive.
The arm recognizer accepts the same 0.25 confidence threshold as the pointer
mapping and no longer requires thumb landmarks, which are often the first
joints lost when both hands are raised.
Tracking loss interrupts the hold and does not release an already-fired latch.
The toggle emits an Armed/Disarmed canvas cue using the presentation settings.
Arming still checks the Canvas target or Computer Accessibility permission.

The same registered command catalog is available through a local stdio MCP
server. Configure a client to launch:

```json
{
  "command": "python3",
  "args": ["/absolute/path/to/sketchcam/script/sketchcam_mcp.py"]
}
```

The SketchCam app must be running. `tools/list` returns one parameterless tool
per registered command, named `sketchcam.<command-id>`. `tools/call` forwards
the command to the app and waits for dispatch acknowledgement (not a guarantee
that a context-dependent command had a visible effect). This is a local bridge:
requests and replies live in the user's private Application Support directory,
not on a network port. The server uses the MCP 2025-11-25 stdio handshake.

This first command surface covers registered app actions, not every value in
every panel. The nose camera-color command is available, but continuous Ink
parameters still need argument-bearing commands before MCP can set them
directly. Some exposed commands edit or clear artwork; clients should request
confirmation before invoking those.
