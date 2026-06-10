# Next Milestones

## Inference

Add a frame consumer that produces semantic state from camera frames:

- hands
- pose
- face
- segmentation
- objects

Inference should update a future scene/state model, not the camera extension.

## State Output

Add OSC and WebSocket outputs from app-side state:

```text
/sketchcam/hand/right/index_tip x y z confidence
/sketchcam/zone/sculpture/touched 1
/sketchcam/event/touch_started hand:right zone:sculpture
```

## Zone Editor

Add a preview overlay for named interaction zones. Zones should be app/runtime state and should not affect the virtual-camera adapter design.

## Sketch Hosting

Add a renderer/runtime layer for p5.js, three.js, WebGL/WebGPU, shaders, or native Metal processors. Each renderer should consume frames, state, controls, and time, then emit rendered frames and optional events.

## Distribution

After Phase 1 works locally, add a Developer ID signed and notarized release path. Do not mix release signing into the first local Camera Extension proof.

