# Audio sources and Text drawing layers

This first implementation adds temporal audio/text streams alongside the existing
pixel/path sources. Microphone and Audio File have separate panels, can run
concurrently, and publish the same packet and analysis contract. Script is a
shared authored text source. Text is a pixel-producing drawing node, with its
own content selection, appearance and playback cursor.

## First manual pass

Build/run the app in Xcode when ready. The generated project now references the
MIT-licensed WhisperKit product from Argmax OSS Swift, pinned to 1.1.1. Xcode
uses the committed `Package.resolved` to resolve its dependencies. The latest
agent pass did not run a build, automated tests, app launch or model download.

For sustained headline cards: apply **Justified headline**, select **Paced**,
and choose **Word envelope → Lifetime → Hold until replaced**. Set Fade in and
Fade out to zero for direct cuts. Speak numbered words across several cards,
pause, then continue. The final card should remain through silence and the next
card should begin with its first received word. Choose **Timed / auto-fade** for
independent word expiry instead. Existing applied/saved looks keep their stored
settings; reapply the built-in look to receive its updated lifetime default.

1. Open **Panels → Script → Dock Right**, and enter a short poem.
2. Open **Panels → Text → Dock Right**. Press **+** to add a Text layer. Select
   **Script**, **N words** (Words=1), and **Next button / command**. Press **Next**: one
   word should appear per press. **Reset** should clear it. Try Chinese and
   Bulgarian text as well as English; glyph fallback uses Core Text and word
   segmentation retains the original punctuation and whitespace.
3. Choose **Stroke start**, draw with the Ink pen, and check that each stroke
   advances one word while continued motion does not. Repeat with **Stroke
   end**. Mouse and motion-controlled Ink strokes publish the same events;
   cancellation does not produce a stroke-end event.
4. Open **Panels → Microphone → Dock Left**. Choose an input and press **Start**;
   grant microphone access. Speaking should update dBFS, voiced pitch and the
   spectrum. Silence/unvoiced audio should show no reliable pitch. Stop should
   clear the live feature readout. This source is never monitored to speakers.
5. For the poem, set **Audio control: Microphone**, **Advance on: Loudness
   crossing**. Adjust **Threshold** above the room noise. Each separate sound
   should advance a word; a sustained sound should advance once. It rearms when
   RMS falls below 65% of the threshold. Try **Pop** and **Voice scale**.
6. For live captions, choose **Content: Microphone speech**, **Drawing:
   Subtitle cues**. In the Microphone panel choose the language, then **Enable
   speech → Download base model & load** (explicit network/model download), or
   load an existing WhisperKit Core ML model folder. Wait for **Ready**. Speak,
   pause, and check provisional text becomes committed text, then disappears
   according to **Word envelope** and **Silence → Idle delay**. **Words/cue** bounds each subtitle cue. Language and
   translation settings apply on model load. Off stops speech independently of
   audio analysis.
7. Open **Panels → Audio File → Dock Left**, select a local audio file, and press
   **Play from start**. Choose **Audio File speech** / **Audio File** on the Text
   layer. With **Listen** off, file analysis/captions should still run silently;
   with Listen on, audio should be audible. Microphone features should remain
   independent. Repeat playback and check stale words do not return from a
   previous session. File selection accepts movie containers, although actual
   decoding depends on AVAudioFile's supported formats.
8. Create a second Text layer with a different style. Verify independent
   cursors, layer opacity/order/masks/effects on the GPU compositor, and inclusion
   in Program and Presentation output. Check the virtual camera output, not
   only the editor preview. Saved scripts, Text configs and routes should
   survive relaunch; microphone capture and speech do not auto-start.
9. Map **Text → Advance text** (`text.advance`) to a gesture sequence using the
   existing input mapping panel. Set **Advance on: Gesture command**. Each
   completed gesture should advance one cue. `text.reset` resets cursors.

## Text drawing and timing

All speech drawing modes now have a separate **Timing** selector, defaulting to
**Immediate** (including older saved layers). Immediate shows the latest
recognizer update without an additional playback queue. Recognition can still
arrive in batches, so N=1 can replace several arriving words at once. **Paced**
replays every received word and adds display delay; it works across all layouts.
Hold controls the final visible text, not recognition speed or per-word pace.

| Drawing | Behavior |
| --- | --- |
| Subtitle cues | Grow a cue up to Words/cue, then replace it with the next cue. |
| N words | A rolling window of the latest N words; N=1 replaces the previous word. |
| Build phrase | Accumulate the current phrase, starting a new page at the configured width/line capacity; a speech pause begins a new phrase. |
| Type-on captions | Fixed top-left alignment in a reserved row block; words stay in place while rows fill, then a new page starts. Speech phrase boundaries restart the page. |
| Fading words | Each word has its own Fade in / Hold / Fade out lifetime. New words do not restart older fades. Recent words wrap within the configured width/lines. |

For stable accumulating captions, choose **Type-on captions**, **Timing:
Immediate**, **Lines: 2**, **Pop: 0**, and **Voice scale: 0**. The caption box
reserves both rows immediately: its top-left baseline stays fixed as the second
line fills. Width/Size determine wrapping and the page capacity; X/Y position
the fixed box. The next word after a full page starts a fresh page. A new speech
phrase (currently the recognizer's approximately 0.6-second energy-gated pause,
or its maximum segment length) also starts fresh. Provisional recognition
corrections can still change words and wrapping. Centered Build phrase and the
centered, reflowing Fading words remain available.

Manual check: start with one word, append several words on the first row, then
continue onto row two. The first word should stay in the same place throughout;
once the second row fills, the next page should begin at the same top-left.
Pause between two short spoken phrases to check the page restarts. Compare
against the centered modes to confirm their existing layout is preserved.

Fading words uses cached glyph tiles with per-word GPU opacity. Words delivered
in the same recognition batch are born together in Immediate timing. Paced
timing introduces them sequentially. The trail is bounded to 128 live words and
shows the latest configured lines when the area fills.

For the next manual pass, use **Timing: Immediate** and **Build phrase**, speak a
short sentence, pause, and speak another. The text should grow without replaying
an older prefix; try a narrow Width / one Line to check page changes. Compare
**N words** with N=1 and N=3, then **Fading words** with Fade out=2 and Hold=0: earlier
words should fade while new words stay bright. Switch Timing to Paced to compare
latency against sequential playback. The speech status shows decoding duration
and pending-job count to help distinguish recognition delay from display delay.

## Caption filtering and local voice commands

Speech Text layers have **Caption filter → Remove filler words**, off by default.
The editable comma-separated list defaults to `um, uh, erm, er, hmm`. Matching
uses whole words, ignores case and surrounding punctuation, and supports custom
words for other recognition languages. Meaningful words such as `like` and
multiword phrases such as `you know` are not removed by default. The filter
changes only this layer's displayed speech; raw transcripts, scripts, word
timestamps and command recognition retain their source data. Filtered word
timestamp entries are omitted in the display copy. Filter settings belong to
Text presets.

**Voice commands** is available in the microphone and Text panels. Enable
**Listen for commands**, then say **voice MCP on** (or toggle **Armed**).
Say **voice MCP off** to disarm. Listening/arming starts off at launch; stopping
speech turns listening off, and stopping the microphone disarms control.
Commands require final microphone recognition, so pause after a command and
allow for decode time. Recorded audio and provisional captions do not execute
commands; each finalized phrase executes at most once. Matching uses the
recognizer's output language (including translation if enabled), before caption
filtering. Full-utterance matching ignores case and punctuation, not extra words.

- **voice next / voice reset**: initial editable mappings to shared Text actions.
- **voice preset bottom captions**: apply the named saved/built-in Text look to
  **Preset layer** in the Text panel, or the first Text layer if none is chosen.
  Sources and scripts remain connected. Unknown/ambiguous names report a status.
- **voice event next**: emit a named event on the shared temporal stream.
- **Add phrase…**: map an exact custom utterance to an existing shared action,
  named event, or Text preset. Mappings persist locally; duplicate phrases report
  an error. The two arming phrases are reserved.

For a poem, set its Script layer to **Advance on → Voice event**, name `poem.next`.
Add a voice mapping `turn the page` → Event → `poem.next`. Once armed, each
separate utterance advances one cue/word. Events use the shared serial stream,
so multiple layers can observe them independently. Event history is bounded
and not saved. Event names match ignoring case and punctuation.

Voice actions use the same registry as keyboard, gestures and local MCP. This
does not launch an AI agent or a new MCP server. Arbitrary natural-language
setting changes and parameter arguments are future work; current mappings can
invoke registered actions and Text looks. Custom phrases/events provide the
integration seam without routing caption text through a language model.

Manual pass: compare `um hello uh world` with filtering off/on; confirm scripts
stay literal. With microphone and speech running, enable listening, say
`voice MCP on`, pause, then `voice preset bottom captions`. Try the poem mapping,
repeat it twice with separate pauses, then disarm and verify it stops advancing.
Play a recording of commands: it should only caption, not execute. Try a custom
action mapping and confirm its normal keyboard action has the same result.
Build/tests/live microphone checks were not run in this pass.

## Recognition annotations as events

Bracketed and parenthesized spans in model transcripts are treated as annotation
candidates: `(clicking)`, `[laughter]`, `(door slams)`, `[BLANK_AUDIO]`, etc.
They are removed from captions, including when mixed with spoken text. Unfinished
trailing spans such as `(click` are held out during partial decoding. Literal
Script content and deliberate silence replacement text bypass this convention.
This also means a parenthetical spoken aside transcribed inside parentheses is
treated as metadata; this is a text convention, not semantic sound detection.

The shared transcript retains `rawText` and typed `annotations` with the original
span, label and normalized name. A finalized phrase emits each annotation
occurrence once on `voiceEvents`, carrying source, phrase ID and timestamp:

- `(clicking)` → `annotation.clicking`
- `[LAUGHTER]` → `annotation.laughter`
- `(door slams)` → `annotation.door_slams`
- `[BLANK_AUDIO]` → `annotation.blank_audio`

Case is folded and spaces/punctuation become underscores in the name. Partial
decodes emit no events, and duplicate final publications do not replay events.
Both microphone and recorded audio produce these events. They are independent
of command listening/arming and do not invoke app actions by themselves.

To use one: select a Script Text layer, choose **Advance on → Voice event**,
and enter `annotation.clicking`. Each finalized matching annotation advances the
script without displaying the annotation as a subtitle. Several layers can
observe the same event independently. Actual detection depends on whether the
speech model emits that label; it is not a dedicated acoustic event detector.

Manual pass: with default Show nothing, check that a recognized `(clicking)` or
`[laughter]` stays out of captions; mixed speech retains its spoken words. Bind
a poem to `annotation.clicking` and verify one advance per finalized occurrence.
Also confirm literal `(clicking)` in a Script still renders, including with
word fades. No build/tests/live recognition run was performed for this change.

## Silence, word envelopes and voice inertia

Each speech Text layer has a **Silence** section. **Show nothing** is the default;
choose **…**, **[blank audio]**, **Custom phrase**, or **Keep last caption**.
Recognizer markers such as `[BLANK_AUDIO]` are classified as no speech rather
than rendered as spoken words. A chosen replacement is a steady caption using
the current typography, not a new speech event. Script content is not filtered.

**Idle delay** controls when a quiet stream becomes blank. Its default follows
the caption hold with a 0.6-second minimum. New words or active source audio keep
the caption active; repeated decoding of identical text does not restart the
idle timer. The activity gate remains energy-based, so it is not a semantic
speech/noise classifier. Keep last caption disables idle clearing but not word
opacity envelopes. Stopping/unavailable audio is treated as idle.

**Word envelope** groups three values, all in seconds:

For ordinary caption modes, **Lifetime → Hold until replaced** sustains the
current card/words until incoming speech changes the cue/page. It ignores timed
Hold expiry and Silence clearing, including explicit blank/annotation-only
results. Fade in still runs on new words; Fade out is used only when words leave
the visible cue. Set Fade out=0 for an immediate card cut, without an outgoing
card overlapping the next one. The built-in **Justified headline** uses this
lifetime by default; reapply the built-in look or choose Lifetime on an existing
layer. Saved presets retain this choice. **Timed / auto-fade** retains independent
word lifetimes and the configured Silence policy. Fading words remains a timed
particle trail.

- **Fade in**: smooth attack from zero to full glyph opacity.
- **Hold**: full-opacity interval after attack.
- **Fade out**: smooth release after Hold, also used when a cue replaces words.

Both fades at zero preserve ordinary caption behavior. Positive fades enable
independent word lifetimes in Subtitle cues, N words, Build phrase, and Type-on.
Fading words keeps its earlier 2.5-second fade when untouched, and uses the same
three controls once edited. Hold=0 with a positive Fade out means no extra
plateau; with both fades off it retains the previous caption-tail convention,
subject to the silence policy. The UI's Hold also updates the speech-caption
tail interval in modes other than Fading words.

Word identities/birth times survive appended text and duplicate final results;
corrections start new lifetimes for changed words. Normal caption modes keep the
layout positions of transparent words until their cue/page changes. Fading words
keeps its existing reflowing trail behavior. Replaced cues can finish releasing
through cached outgoing glyph tiles. The box follows the largest word opacity;
word fades multiply the Text color's base opacity. Fonts, wrapping and glyph
positions are shared with the static renderer, and opacity changes happen over
cached GPU image tiles rather than rebuilding glyphs on every frame.

Paced playback keeps a bounded history of the latest 64 transcript phrases per
audio source, so a phrase isn't lost merely because another result arrived
before a render frame. Blank/annotation-only results no longer reset the queue.
Revisions preserve already-presented words, update their separators, and align
the delivered suffix before replacing the waiting tail. This prevents an earlier
deletion from moving a numeric cursor past an unshown word. Unchanged history
entries reuse their processed inputs. A newly attached/switched layer starts at
the latest phrase rather than replaying the old history. This preserves received
words in paced playback; it cannot recover words omitted by recognition itself
or prevent the decoder's documented overload drops. Immediate timing can still
jump across words/cue boundaries when recognition delivers several words at once.

Manual card test: reapply Justified headline, choose Paced timing, Fade in=0,
Fade out=0, and Lifetime=Hold until replaced. Speak numbered words across several
cue boundaries, then remain silent: the last card should stay visible. Continue
speaking: each new cue should begin with its first received word. Set a short
Hold and positive Fade out in Timed mode to compare automatic fading. Repeat
with filler removal enabled. Tests for history, partial-word separators, prefix
deletions and sustained captions were authored but not run; build/live checks
remain manual under the repository instructions.

**Motion response** is independent of those opacity envelopes:

- **Pop**: a short size bounce on arriving text or script advances. It is not
  driven by microphone loudness.
- **Voice scale**: continuous size modulation from the selected Audio control
  stream's RMS loudness, whether or not recognition is enabled.
- **Voice rise / Voice fall**: separate inertia for increasing/decreasing size.
  Each is the time to move 90% toward a changed target. Zero responds immediately.
  These controls do not delay words or change their opacity.

Native hover tips cover the Text, typography, preset and audio controls, including
units and source distinctions. These settings are included in saved Text looks.

Manual pass: use Subtitle cues, Immediate timing, Fade in=0.15, Hold=0.8,
Fade out=0.4, Pop=0 and Voice scale=0. Speak or advance a script: individual words
should appear, remain, and fade while their positions stay fixed. Repeat with
Type-on and N words. Set both fades to zero to compare the original behavior.
For voice-only response, keep Pop=0, set Voice scale=0.4, Rise=0.1 and Fall=0.6;
make a short sound and check that size grows quickly and settles slowly. Then
set Voice scale=0 and Pop=0.4: advancing a script should bounce without sound.
Finally test each Silence choice with a quiet microphone, stopped file, and
custom phrase; default should not expose recognizer blank-audio markers. Save,
reload, and JSON round-trip a Text preset containing all these settings.

No build, automated tests, microphone run or performance measurement was executed
in this pass; project generation and static checks only. Regression cases were
added for envelopes, asymmetric response, silence classification, stable word
identities and outgoing releases.

## Typography and Text presets

**Font** selects from installed macOS families (searchable) and faces, or an
explicit font name. Bold/Italic add symbolic traits where supported. Case is
Original/UPPERCASE/lowercase and only changes rendering; the authored script or
recognized transcript is retained. Size is a percentage of output height;
Tracking is additional letter spacing in em units; Leading is a line-height
multiplier. Core Text fallback supplies glyphs for multilingual text.

**Layout** includes Mode default/Left/Center/Right/Justified alignment, X/Y and
width, maximum rows, horizontal/vertical padding in em units, and box corner
radius. Mode default keeps Type-on left-aligned and other modes centered.
Justified normally leaves the last line ragged; **Justify last line** stretches
it too for graphic title treatments. Justifying an accumulating line can change
existing glyph positions, so use Left + Fixed font size for stable type-on text.

Enable **Fixed box height** to set an explicit height, Top/Center/Bottom vertical
alignment, and Fixed/Shrink to fit/Fit box font sizing. Fit uses font metrics to
change point size, preserving glyph proportions. Shrink never exceeds the
requested size; Fit box can also enlarge. Font fitting and full justification
are expressive choices and can move existing text as content grows. Wrapping,
pagination, and rendering share the same font/spacing/padding measurements.
Fading words uses the same controls and independent per-word opacity; its Box
color is drawn behind individual word tiles.

**Text presets** follows the Portrait preset workflow: save a named look, apply
it, replace it with the current settings, delete it, or import/export JSON.
Names replace existing saves case-insensitively; imports receive a unique name
and never overwrite an existing look. Applying a preset affects only the
selected Text node's configuration. Source bindings, script text, other layers,
audio capture, and loaded speech models are preserved. Drawing, animation, and
script advance settings are part of the look. Fonts are named, not embedded.

Built-in starting looks:

- **Bottom captions** — left-aligned two-row Type-on, with readable padding.
- **Monochrome flash** — Monaco, uppercase, black text on a white full-frame
  box, fitted centered words, timed script cues.
- **Justified headline** — bold caps, tracking, justified final lines.
- **Typewriter** — Menlo, four-row Type-on, transparent box.
- **Fading words** — transparent, independently fading word tiles.

The monochrome starting look is informed by the Monaco text/music approach
[documented by M+](https://www.mplus.org.hk/en/magazine/yhchi-acquisition/).
It is not a recreation of a specific work. The supplied YouTube clip could not
be retrieved during this pass. Exact authored beat synchronization, cuts,
per-cue font/position changes and musical choreography need a cue/timeline layer
beyond these shared appearance settings and timer/event triggers.

Manual pass: load Monochrome flash in Text presets, choose Script content and a
short text, and observe the uppercase fitted cue changes. Try each alignment,
padding and font face; compare Fixed and Fit box. Save a named look, change it,
reload it, export it, import it under a new name, then relaunch and verify the
saved looks remain. Check that content/audio bindings and other layers survive
every preset application. Test Type-on with Left/Fixed/Pop=0/Voice scale=0 to
confirm stable placement, and try Bulgarian/Chinese glyph fallback after changing
fonts. Project generation and static checks only were executed; the new
regression cases have not been run.

## Stream contract

`SketchCamCore/Sources/TemporalStreams.swift` defines:

- `AudioPacket`: source ID, session ID, host-uptime timestamp, source-relative
  media time, native sample rate and mono Float PCM.
- `AudioFeatures`: RMS amplitude, peak, dBFS, optional voiced pitch in Hz with
  confidence, linear spectrum magnitudes with bin spacing, three frequency
  bands (<250 Hz, 250–2000 Hz, >2000 Hz), and an energy-based activity gate.
- `TranscriptPhrase`: stable phrase ID, provisional/committed status, language,
  content, host update time, and source-relative word times/confidences.
- `TemporalStreamStore`: non-consuming snapshots/events, bounded raw PCM history
  (eight seconds per source), and independent audio subscribers. A subscriber
  receives native packets plus features on the producer's analysis queue; it
  must enqueue expensive work and unsubscribe when done.

Consumers can subscribe through `model.audio.streams.subscribe`, filter by
`packet.source`, or read `snapshot()` / `recentAudio(source)`. This is separate
from the existing spatial GPU control-field graph: an audio scalar is not a
canvas-sized texture. The Text node's typed ports are `content: text` and
`audio: audio`. Other consumers can adopt the same audio port/feature contract.

Audio callbacks copy their borrowed buffers into a bounded analysis queue.
FFT/pitch and raw-history publication run there. Speech has a bounded/coalescing
queue and a shared serial decoder; camera/Metal rendering never waits for it.
Missed audio under overload starts a new recognition segment rather than
silently pretending source time was contiguous. Script edge events also use a
bounded, non-consuming event history; multiple Text layers see the same event.

The renderer uses the existing drawing-image path for both GPU and Core Image
compositing. Core Text glyph rasters are cached by content/config/output size;
per-frame pop and loudness modulation transform the cached image. Script,
font/color/placement, timing options and bindings persist with settings/layers;
PCM, speech results, event history and playback cursors are transient.

## Current limits

- This is a first live test, not a benchmarked low-latency transcription system.
  Partial decoding is requested about every 0.5 seconds, phrases finalize after
  about 0.6 seconds below the activity gate or 15 seconds of continuous input.
  Actual latency depends on model, machine and concurrent SketchCam workload.
- The activity detector is an energy gate, not a neural speech/noise classifier.
  Pitch is autocorrelation-based and may be unavailable or octave-ambiguous.
  dBFS is relative digital amplitude, not calibrated SPL or perceptual LUFS.
- Decoder progress is published during inference, without rewinding the old
  visible prefix when a rolling pass starts over. Partial passes omit costly word
  alignment; finalized phrases retain word timestamps. This is still a windowed
  recognizer, not a guarantee of immediate acoustic word detection. Decoder
  progress excludes incomplete final Latin/Cyrillic words; CJK characters can
  appear without spaces. Model corrections can still revise provisional text.
- Immediate timing can replace multiple batched words at N=1; use a larger N,
  Build phrase, Fading words, or Paced timing when every received word needs a
  visible interval. Neither timing option promises sample-accurate karaoke.
- File playback is independent, at normal speed, with Play from start/Stop and
  optional listening. Pause/seek/loop, session bookmark restoration, shared
  movie/audio transport, offline transcription/alignment and editable cue
  timelines are future work. Audio is not multiplexed into movie exports or
  the virtual camera, which remains a video output.
- Text animation follows SketchCam's existing camera/movie/fallback render
  clock. Audio analysis itself does not depend on incoming video frames.
- Continuous vertical scrolling, horizontal tickers, random word placement and
  attachment to mouth/hand/finger landmarks are follow-ups. Current Text layout
  uses configured frame coordinates, alignment, wrapping and padding.
- English, Chinese and Bulgarian are offered as Whisper language selections;
  accuracy and speed on each still require a real microphone/file test. A local
  model folder must contain WhisperKit Core ML models, not whisper.cpp/GGUF.
  The model's tokenizer may need an initial download/cache as well.
- **Translate into English** uses Whisper's translation task; arbitrary target
  languages require a separate translator. Select a multilingual non-turbo
  model for this task. Source-language recognition works independently.
- One shared Script source exists initially; each Text layer advances its own
  cursor. Events currently address all Text layers matching their selected
  trigger. Per-producer event ports, multiple named script sources, and generic
  pitch/spectrum-to-parameter mapping are extension points, not completed UI.
- The GPU compositor provides the existing full layer effects/mask/workspace
  treatment. The older Core Image compositor supports basic ordered text and
  opacity with its existing limitations.

## Verification status

XcodeGen project generation, plist validation and whitespace/diff checks are the
only checks executed by the agent. Authored regression coverage includes typed
routes, older settings, bounded/non-consuming streams/events, audio analysis,
multilingual segmentation, stroke/voice/annotation-driven scripts, preset
round-tripping, layout stability, word envelopes, voice inertia, silence/filler
filtering, command arming/deduplication and paced-queue revision/history handling.
These tests have not been run in this pass. The user has reported live progress
and caption issues during manual iterations; the latest queue and sustained-card
changes still need a manual build/run. No performance or virtual-camera output
claim has been verified by the agent.
