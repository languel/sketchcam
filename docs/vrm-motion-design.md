# VRM Character Direction

This is a design note for a future, optional character workflow. It is not part
of the current Portrait implementation and must not replace the live drawing
algorithms. The user's preferred direction is to keep Portrait's expressive,
improvisational line language while making its important gestures follow
semantic landmarks; VRM is a second way to make a character from the same motion
source.

## Product boundary

Treat a VRM character as another visual source in the composition, not as a new
Portrait algorithm:

```text
camera / hand tracking
        |
        +--> landmarks --> Portrait drawing
        |
        +--> semantic motion signals --> VRM retargeter --> character layer
                                      \\--> Motion Control events
```

Portrait remains valuable for loose, live line art and does not need a complete
rig. A VRM avatar can provide a more legible body, deliberate silhouette, and
authored identity. Both should be allowed in the same composition, independently
enabled and layered.

## Smallest useful sequence

1. **Inspect and preview:** import a local `.vrm`, validate its version and
   humanoid skeleton, show a rest-pose preview, and report unsupported features
   without silently mutating the asset.
2. **Drive a character:** map available pose joints to humanoid bones and face
   landmarks to expression weights. Use confidence-aware smoothing and keep the
   skeleton's rest pose as the source of missing data.
3. **Author mappings:** expose compact controls for bone offsets, axis
   correction, range, smoothing, confidence, and expression gain. Save these as
   a rig profile separate from the source character.
4. **Make and draw characters:** only after playback and persistence are solid,
   consider an in-app drawing/rigging workspace. It should author VRM-compatible
   characters rather than turning Portrait's procedural line grammar into a
   forced rigging system.

The first milestone should be preview plus a narrow, testable retargeted motion
set (head, torso, shoulders/elbows, and wrists). Finger bones, eye gaze, mouth
phonemes, physics, and a full rig authoring environment are later capabilities,
not prerequisites for validating the layer boundary.

## Shared motion contract

Do not let a renderer depend directly on Vision request objects or UI state.
Introduce a timestamped semantic pose packet at the tracking boundary with:

- normalized joints and optional 3-D/depth estimates;
- confidence and freshness per joint/feature;
- head orientation and scale when available;
- named expression signals (eye openness, mouth opening, blink, brow lift,
  pinch/fist/open-palm, and pointer position);
- source identity and mirroring/orientation metadata.

Portrait can continue consuming its existing `MappedGroup`s during an initial
VRM prototype. An adapter can translate those groups into this shared contract
later. That avoids a risky migration of the drawing algorithms before there is
a proven second consumer.

## Runtime and safety constraints

- Keep model or avatar updates off the camera capture callback; publish the
  newest pose to a bounded latest-frame channel so tracking cannot build a
  render backlog.
- Treat low-confidence joints as missing. Blend toward the rig's rest pose and
  release stale motion smoothly rather than snapping or freezing indefinitely.
- Preserve source scale and coordinate metadata; make mirror compensation
  explicit so left/right anatomy stays correct.
- Keep external computer control behind the existing explicit arm/disarm and
  Accessibility flow. Avatar movement alone must not post system events.
- Keep character assets local by default. Do not upload user camera frames or
  imported characters to a hosted model service.

## Segmentation and model selection

The current Vision person contour remains the lightweight first option for
line-based silhouette work. The gesture portrait does not require segmentation.
Do not add a large model just to make the authored scalp/body shapes move.

SAM 3 is an interesting research reference, but its current official repository
describes an 848M-parameter model, CUDA/NVIDIA runtime requirements, and
access-gated weights; that is not a drop-in real-time macOS/CoreML dependency.
RF-DETR offers smaller instance-segmentation variants and publishes latency
benchmarks, but those figures are not evidence of performance on the target Mac.
Before adopting either, prove local conversion/runtime support, distribution
terms, memory use, and sustained camera-to-output latency on the actual Apple
Silicon target. A small optional asynchronous segmentation provider should have
a Vision fallback and must never stall the character or drawing frame loop.

References: [VRM 1.0 specification](https://vrm.dev/en/vrm1/), [SAM 3
repository](https://github.com/facebookresearch/sam3), and [RF-DETR
repository](https://github.com/roboflow/rf-detr).
