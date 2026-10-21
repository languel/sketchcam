# Getting started

SketchCam is a macOS camera, drawing and performance tool. It combines video,
procedural portraits, an interactive ink canvas, reactive text and shared input
streams. The current prerelease requires **macOS 26 or newer**. Check the release
notes for the architectures included in a particular download.

## Install

1. Download the app ZIP from [GitHub Releases](https://github.com/languel/sketchcam/releases).
2. Unzip it and move **SketchCam.app** to **Applications**.
3. Open the app. Allow camera access when you want live video.
4. To use it in another app, activate the **Camera Extension** in SketchCam,
   approve it in System Settings when prompted, then restart SketchCam.
   On macOS 26 the approval is under **General → Login Items & Extensions →
   Camera Extensions**.
5. Select **SketchCam** in your video app's camera picker.

For development snapshots, successful `main` Actions runs also contain signed,
notarized app ZIPs. Download the `SketchCam-notarized-…` artifact, unpack its
outer ZIP, then unpack `SketchCam.zip` and install as above. Artifacts are retained
for 14 days; deliberately published release downloads are separate.

## Try a first session

- Open **Camera** to choose the input. Use **Movie** for prerecorded video.
- Use **Layers** to combine sources, effects, drawing passes and materials.
- Try **Portrait**, **Yarn**, **Wrap** or **Line walk** for drawing from tracked
  features. **Marks** lets you inspect those features.
- Use **Ink** and **Paper** for the interactive drawing canvas. **History**
  provides undo/redo and the history-depth controls.
- Open **Microphone**, start capture, then explicitly enable/load a speech model.
  Add a **Text** layer and choose **Microphone speech** for live captions.
  The first model load may download model/tokenizer files; inference then runs
  locally. Microphone capture and model loading are separate actions.
- For a poem or prepared text, enter it in **Script** and select **Script** on
  a Text layer. Choose a timer, stroke edge, loudness crossing or named event
  to reveal words. Try a built-in Text look to explore layout styles.
- Use **Input Map** for gesture controls. Arm control explicitly before use;
  **Escape** disarms it. Computer-wide pointer control also needs macOS
  Accessibility permission. Canvas controls do not need that permission.

Panels can be docked or floated. Hover over parameters for their purpose and
units. **Keys** lists configurable shortcuts, including freeze/pause and frame
export. **Output** provides a separate output/presentation window.

## Virtual-camera checks

Try QuickTime Player's **New Movie Recording** camera menu, FaceTime's video
menu, or a browser's camera selector. OBS and Zoom also provide camera pickers;
host behavior and alpha support vary. The camera extension generates a fallback
pattern when it has no host frames, so that pattern does not confirm the live
SketchCam feed is connected.

The virtual camera is video-only: microphone/file audio analysis and captions do
not provide a virtual audio device or add audio to video exports. If the camera
is missing after activation, restart SketchCam and the receiving app. Further
diagnostics are in the [troubleshooting notes](../notes/troubleshooting.md).

## More control

- [Full feature reference](features.md)
- [Audio, text, caption timing and voice commands](audio-text-streams.md)
- [Motion controls, gesture sequences and local MCP](motion-tools.md)
- [Portrait drawing](portrait-drawing.md)
- [Build from source and local development](development.md)
