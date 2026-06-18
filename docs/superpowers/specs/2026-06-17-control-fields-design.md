# GPU Control Fields Design

## Goal

Introduce a reusable GPU-resident control-field layer that lets simulations consume spatial scalar values and directional vectors without coupling those sources to Ink or Acrylic. This is the first dependency for physical paper response, tracked-human motion, dense optical flow, and future control routing.

## Field contract

Add two control-field kinds:

- Scalar fields store a normalized value per simulation cell for masks, magnitude, absorbency, drag, and resist.
- Vector fields store a signed two-dimensional value per simulation cell for velocity and directional forces.

A field provider declares its field kind, extent, revision, update cadence, and Metal texture. Consumers sample fields in normalized canvas coordinates and provide their own strength, inversion, threshold, and fallback behavior. Static fields update only when their provider revision or dimensions change. Live fields update at their declared cadence.

The contract stays GPU-resident from generation through consumption. It must not require CPU texture readback, `CGImage` conversion, or per-frame resource allocation. Fields use the Ink simulation resolution by default and are resampled when a consumer uses a different resolution.

## Routing and lifecycle

Control fields are routable resources, distinct from visible pixel layers and path sources. A provider may publish multiple named outputs, such as `motionMagnitude` and `motionVector`. A consumer stores an optional provider/output reference; a missing, disabled, incompatible, or unavailable provider resolves to a zero field.

Resources are allocated lazily when a routed consumer is active, pooled by dimensions and format, and released when no consumers remain. Cycles in control routing are rejected. Disabling a provider removes its update cost while preserving consumer settings.

Initial providers are procedural Paper Response, Tracked Human Motion, and Optical Flow. Initial consumers are Ink and Acrylic. The interface must remain general enough for later masks and effects without adding those consumers now.

## Settings and compatibility

Persist provider identity, output name, enabled state, update quality, and consumer strength. Existing settings decode with no control-field routes and therefore preserve current rendering and simulation behavior exactly.

The layer UI distinguishes visible inputs from control inputs. Control routing displays the provider and named output, and incompatible field kinds are not offered.

## Diagnostics and validation

Add per-provider GPU timing and update counters. Tests cover deterministic static revisions, zero-field fallback, scalar/vector type checking, coordinate mapping, cycle rejection, lazy allocation, and no updates while disabled. A synthetic provider must demonstrate that the same scalar or vector texture can drive both Ink and Acrylic without provider-specific code in either solver.
