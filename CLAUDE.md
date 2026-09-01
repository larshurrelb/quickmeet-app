# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A macOS meeting recorder and note taker. Records the microphone *and* system audio as two
separate streams, transcribes both with Gemini 3.5 Transcribe (diarized, word timestamps),
merges them onto one clock and writes notes. A regular app — Dock icon, menu bar item and
main menu, `setActivationPolicy(.regular)` — assembled from a SwiftPM executable into an
`.app` by `build.sh`. No third-party dependencies, and it should stay that way.

It was `LSUIElement` for a while, and the reason it is not any more is that the meetings
window had no way back once it was closed: the only door was a small icon in the menu bar.
Dropping `LSUIElement` means the app needs a main menu of its own — without one there is no
⌘Q, no ⌘W, and no Cut/Copy/Paste in any text field, including the one the API key goes
into. `AppDelegate.buildMainMenu` builds it, and `applicationShouldHandleReopen` is what
makes clicking the Dock icon bring the window back.

Sibling to QuickTalk (push-to-talk dictation). Several files are ports of its hard-won
code — `MicRecorder`, `KeyStore`, `Diagnostics`. **Fixes to shared logic should be
considered for both projects**; they are separate repos on purpose (different permission
surface, different audience, different legal posture) but the audio layer has a common
ancestor.

## Build and run

```bash
./build.sh
```

Compiles, signs, installs to `/Applications`, removes the build-folder copy. There is no
Xcode project — don't add one.

- The build signs with the user's **Apple Development** certificate when present. Do not
  "simplify" this back to ad-hoc: an ad-hoc signature changes with every code change,
  which silently invalidates every granted permission.
- **Never leave a second copy of the app on disk.** TCC keys permissions on path *and*
  signature, so a copy in the build folder is a separate identity to macOS and shows up as
  a duplicate "QuickMeet" in the Privacy lists.

## Hard-won gotchas

Each of these was measured, not assumed. Don't rediscover them.

### Core Audio process taps

- **A tap-only aggregate device silently delivers nothing.** This is the big one. Building
  the aggregate from the tap alone — no hardware sub-device — looks like the safe design
  and passes every check you would naturally write:
  `AudioHardwareCreateAggregateDevice` returns `noErr`, the device reports the tap's two
  input channels, `AudioDeviceCreateIOProcIDWithBlock` returns `noErr`,
  `AudioDeviceStart` returns `noErr` — and the IOProc is then **never called**. Zero
  frames, not silence. Measured against the anchored form, which delivered 281,600 frames
  in the same three seconds.
  → The aggregate **must** be anchored to a real output device via
  `kAudioAggregateDeviceMainSubDeviceKey` + `kAudioAggregateDeviceSubDeviceListKey`.
- **No output device clocks while nothing is playing** — not a Bluetooth default, not the
  built-in speakers. Core Audio idles the device, the aggregate stops, and the IOProc is
  simply not called. So **receiving no frames is not a failure**, and must never be
  reported as one: for the opening stretch of a meeting, before the far end speaks, it is
  the normal state. A graph opened while the device is idle **recovers on its own** the
  moment audio starts (measured: 243,712 frames). An earlier version warned "system audio
  isn't being delivered" at 1.5 s and rebuilt the aggregate against a different clock
  device to "fix" it — both wrong, and the measurement that suggested the built-in output
  was immune had been contaminated by the trial before it, which played a sound.
- Because the device does not run during silence, the system stream **must be padded to
  wall clock** or it comes out shorter than the meeting: the silence is squeezed out, every
  later timestamp slides earlier, and the system turns interleave against the microphone's
  at the wrong points. `capture()` compares `mHostTime` between callbacks — mach absolute
  time, because the device's own sample clock stops when the device does — and calls
  `PCMStreamWriter.padSilence`. The gap clock is anchored in `start()`, not at the first
  callback, so the leading silence before the far end first speaks is padded too.
- The one condition worth surfacing mid-meeting is the *opposite* shape: frames arriving
  and every sample zero. The device is demonstrably running, so something is playing and
  none of it is reaching us — a refused permission. `healthHint()` reports only that, and
  only after 20 s.
- **A refused permission looks like silence, not an error.** macOS runs the IO cycle and
  hands over zeros. It can only be diagnosed at the end, which is what
  `wasSilentThroughout` is for.
- There is **no public API** to read or request the System Audio Recording permission. The
  first `AudioHardwareCreateProcessTap` is both the request and the answer, which is why
  Settings offers a "Check permission" button that actually opens a tap rather than a
  status light that guesses.
- Anchoring to a Bluetooth output device is **safe on current macOS**, contrary to the
  obvious worry inherited from QuickTalk. A Bluetooth headset is presented as *two*
  devices and the output half has zero input channels (verified on a Bluetooth headset: `2/0` output, input a separate device), so
  putting it in an aggregate never opens its microphone — and opening the microphone is
  what triggers the A2DP→HFP collapse. Still worth re-checking if the symptom reappears.
- **The tap delivers ONE INTERLEAVED buffer, not one buffer per channel.** Measured:
  `mNumberBuffers = 1`, `mNumberChannels = 2`, `mBytesPerFrame = 8`,
  `kAudioFormatFlagIsNonInterleaved` clear. An early `capture()` selected only buffers with
  `mNumberChannels == 1`, matched nothing, and silently discarded every frame — which
  presented as "system audio isn't being delivered" *with the permission correctly granted
  and the tap running perfectly*. `capture()` now walks channels globally so it is correct
  for interleaved, one-per-channel, and the mixture an aggregate produces.
  → **The testing lesson is the bigger one:** the harness that "verified" the tap had the
  channel filter removed from it, so it exercised a different code path than the app
  shipped. Drive the real type (`SystemAudioRecorder.start`), never a re-implementation of
  what it is supposed to do.

### Measuring a tap without fooling yourself

Three separate false results came out of careless harnesses. All of them looked like app
bugs.

- **The tap excludes our own process.** `stereoGlobalTapButExcludeProcesses: [ourselves]`
  is deliberate, so a harness that plays its own `NSSound` and then reports "no frames" is
  measuring the exclusion working correctly. Play the audio from **another process**
  (`afplay` via `Process`).
- **One trial per process run.** Audio from a previous trial leaves the output device awake
  for a while, so a later "silent" trial in the same process still sees a running clock.
  That is exactly how the built-in output was wrongly credited with clocking while idle.
- **`NSSound` must be retained** (and usually `loops = true`). `NSSound(named:)?.play()` on
  a temporary in a console tool plays nothing, which reads as a dead tap.
- An unsigned harness has no System Audio Recording grant, so `peak` is always `0.0000`
  there. That is the correct result and it exercises the "played but silent → permission"
  path; it can never confirm content.
- Channel order in the aggregate is sub-device channels first, tap channels appended. Only
  the tail belongs to the tap; the head could be the anchor's own microphone. Hence
  `channelOffset` — which is a *channel* index, not a buffer index.
- `CATapDescription`'s Swift initialisers take `[AudioObjectID]`, **not** `[NSNumber]` as
  the Objective-C signature suggests. A pid must be translated first via
  `kAudioHardwarePropertyTranslatePIDToProcessObject`.
- `muteBehavior` must be `.unmuted`. A muted tap records the call and stops the user
  hearing it — in a meeting that means deafening them to the people they are talking to.

### Gemini API

The configuration here is **deliberately different from QuickTalk's**, and each difference
was a wrong turn first.

- **`mode` is an object here, not a string.** `"mode": "smart"` is shorthand. Word
  timestamps and diarization live in the long form,
  `{"type": "verbatim", "timestamp_granularities": ["word"], "diarization_mode": "speaker"}`.
  Sending the string with extra sibling keys parses and gives you neither.
- **Smart mode is unavailable.** The API rejects `smart` together with `diarization_mode`
  or `timestamp_granularities`. Smart is what makes QuickTalk readable, so all structure
  here has to come from the notes pass instead. Don't try to re-enable it.
- **Never add `language_codes`.** Same prohibition, same reason as QuickTalk: omitting it
  is what gives automatic per-utterance detection, and a meeting is far more likely to be
  bilingual than a dictation.
- **Never add `custom_vocabulary`.** It is documented as combinable with diarization and
  is in fact rejected with HTTP 400 — `custom_vocabulary is incompatible with
  diarization`. Reported and unresolved as of 2026-08-31.
- **Diarization caps a request at 30 minutes** (an hour without it). This is the entire
  reason for `AudioChunker`.
- Word timings arrive as `steps[] → content[] → annotations[]` with `type: "word_info"`,
  carrying `text`, `speaker`, `start_offset`, `end_offset`. Offsets are strings with a
  unit suffix — `"12.480s"`. Not `candidates`.
- **Silence returns HTTP 200, `status: "completed"` and no `steps` key.** Not an error —
  half the chunks of a real meeting are one side listening. Return an empty word list.
- Diarization is 8 speakers max, experimental beyond 2. That is a supporting reason for
  the two-stream design, not the main one.
- **The speaker label's shape is not contractual.** `spk_1`, `spk:0` and `speaker 2` have
  all come back from the same endpoint, and the numbering starts at 0 as often as at 1. A
  parse that only understood `_` put "Spk:0" on screen and, in `TranscriptBuilder`, handed
  two people who joined after different chunk boundaries the same stitched label. Nothing
  user-facing derives from the label's text now: `SpeakerDirectory` numbers remote speakers
  from the order they first speak, from 1. `SpeakerID.legacyName` exists only to find the
  old spellings inside notes that were written before that.

- **Speaker names and colours come from `SpeakerDirectory`, built once per render or
  export.** They used to be methods on `Meeting` — `name(for:)`, `speakerIndex(for:)`,
  `speakers`, `substituteNames(in:)` — and each of them walked the whole turn list, while
  every caller wanted all of them *per line*. `markdown()` was therefore quadratic in the
  number of turns, and so were the transcript pane and the notes prompt. Build the directory
  at the top of whatever is about to render and hand it down; don't put those methods back
  on `Meeting`. It is deliberately *not* cached on the meeting either: turns change when a
  transcript is re-run and names change when the user renames somebody, and a stale
  directory puts the wrong name on the wrong voice.

### The two-stream design

- The microphone is recorded separately because it is **`you` by construction**. The most
  important speaker split in any meeting never goes through a model. Do not "simplify"
  this into one mixed track — it would throw away the only attribution that is certain and
  hand the whole problem to a feature that is experimental past two speakers.
- Diarization is asked for on the **system stream only**. Asking for it on the microphone
  would invite the model to split one voice in two.
- **Chunks must overlap**, and the overlap is load-bearing rather than defensive. Speaker
  labels are only meaningful within a single request, so the shared stretch of audio is
  what lets `TranscriptBuilder.speakerMapping` match chunk 2's `spk_1` onto chunk 1's
  `spk_2` — by temporal voting, no extra model call.
- Speaker mapping is a **greedy one-to-one assignment**. Two new labels must never collapse
  onto one established speaker; merging two people permanently is worse than leaving a
  stranger unmatched.
- **The seam cuts both sides.** Trimming only the incoming chunk leaves everything after
  the seam duplicated, because the previous chunk transcribed the whole shared stretch too.
  `assembled.removeAll { $0.start >= seam }` is not optional — this was a real bug caught
  by the self-test.
- Echo removal exists because a user on speakers has their microphone hear the far end, so
  the same sentence arrives on both streams with `you` on the wrong copy. Turns shorter
  than 3 content words are **never** dropped — "yeah", "mhm" and "exactly" are things
  people genuinely say over each other.

### Reading totals after stopping

- **`peakLevel` and `duration` must survive `stop()`.** Both were computed straight through
  to the writer (`writer?.peakLevel ?? 0`), and `stop()` releases the writer — so every
  caller that asked after stopping got zero, which is the only moment anyone asks. A
  25-second recording with a healthy 0.21 peak reported as silence, `wasSilentThroughout`
  fired, `systemAudioCaptured` was set false, and the pipeline then skipped the file: the
  user got a transcript with only their own voice in it, from a recording that was
  perfectly good on disk. The recorders now latch `finalPeak` / `finalDuration` before
  releasing the writer.
- **Gate transcription on the audio, never on a flag.** `TranscriptionPipeline` used to read
  `meeting.systemAudioCaptured ? chunk(…) : []`. That flag comes from a health check and a
  peak reading — advisory metadata — and when it was wrong, real audio was silently
  discarded. It now chunks whatever file has duration, and per-chunk silence detection
  (which looks at actual samples) decides what is worth a request. The flag is corrected
  afterwards from the finished transcript.

### Audio capture and writing

- **Capture is a raw AUHAL, not `AVAudioEngine`.** Ported wholesale from QuickTalk:
  `AVAudioEngine.start()` silently rebinds its input to a `CADefaultDeviceAggregate`
  wrapping the *default* device, discarding whatever was set on the input node. That made
  the microphone picker do nothing for months. Don't move it back.
- **Always resolve "system default" to a concrete `AudioDeviceID`.** Asking CoreAudio for
  "the default device" is what builds the aggregate that drags the Bluetooth microphone in.
- Store the CoreAudio **device UID**, never the numeric `AudioDeviceID` (stable only
  within a boot).
- **No disk I/O on the audio thread.** QuickTalk calls `AVAudioFile.write` straight from
  the render callback, which is fine for 15 seconds and wrong for an hour — `write` can
  allocate and block, and a blocked callback is a hole in the recording. `PCMStreamWriter`
  converts on the audio thread and drains to a `FileHandle` on a timer four times a second.
- **The WAV header is written first with placeholder lengths and patched at close.** A
  recording interrupted by a crash is still a file with valid PCM in it;
  `PCMStreamWriter.repair(at:)` patches the lengths from the file size on the next launch,
  and `MeetingStore.recover` calls it. Losing an hour of someone else's meeting to an
  unfinalised container is not acceptable — which is also why the master is PCM and not
  AAC. Truncated AAC with no `moov` atom is unreadable.
- Compression happens per chunk at **upload** time, to AAC in an m4a container
  (`audio/m4a` is on the accepted MIME list). ~13 MB/hour against 115 MB/hour for PCM.
  `AVEncoderBitRateKey: 32_000` **is** honoured — measured at 29.8 kbps over 30 seconds.
  Beware measuring this on a 2-second file: container overhead dominates and it looks
  broken when it is not.
- Level metering is on a **dB scale**, not linear RMS. Conversational speech is ~0.02 RMS,
  which is near the floor linearly and around 0.5 on the dB mapping.
- Silence threshold 0.006, from QuickTalk's measurements: silence peaks 0.000–0.002,
  speech 0.019+. Silent chunks are never uploaded.

### Permissions and UI

- **⌥⌘R is a Carbon `RegisterEventHotKey`, and that is why it needs no permission.**
  QuickTalk needs a `CGEventTap` because it watches a key being *held*, which costs an
  Input Monitoring grant and a relaunch. A meeting is started and stopped, not held. This
  is the entire reason QuickMeet's permission list is two items long instead of four.
  Don't replace it with an event tap.
- The recording HUD is an `NSPanel` with `.nonactivatingPanel` so it floats over
  full-screen apps — where video calls live — without stealing focus. It sits top-centre,
  flush with `visibleFrame.maxY`: the menu bar is excluded from `visibleFrame`, and the
  notch lives inside the menu bar, so that edge *is* the underside of the notch on notched
  and un-notched displays alike. The view's own outer padding supplies the gap and the room
  the glass needs inside the panel bounds.
- **`glassEffect` must be applied to the content, not placed behind it.**
  `.background(Color.clear.glassEffect(…))` compiles and renders a washed-out
  approximation — the effect has to own the view it is shaping or it has nothing to
  refract. Use `.glassEffect(.regular, in: .rect(cornerRadius:style:))` as a modifier on
  the padded content, with `.ultraThinMaterial` under `#available(macOS 26)` as fallback.
  `.buttonStyle(.glass)` is available on macOS 26 for controls sitting on the panel.
- **There is no way to hide the recording indicator, and that is a product rule, not an
  oversight.** No stealth mode, no hiding the menu-bar item while recording, nothing that
  suppresses it. It is both the legal posture and the reason the project is defensible to
  publish. Requests to add one should be declined.
- The status menu is rebuilt in `menuWillOpen` rather than pushed to from elsewhere.
  `SettingsWindowController.reloadIfVisible()` handles the other direction, because the
  SwiftUI view seeds its `@State` at construction.
- **`NSHostingView.sizingOptions = []` zeroes `fittingSize`.** QuickTalk sets it on its
  rules window because a bare `TextEditor` reports an unbounded ideal height that drags the
  window with it. That fix is only correct for a window with an *explicit* size. Applied to
  a window that computes its size *from* `fittingSize`, it reports `(0, 0)` — and a 0×0
  window is created, ordered front, made key, and completely invisible. The symptom was
  "clicking Record Meeting does nothing": the first-run consent window was opening at zero
  size every time, with nothing in the log to say so. Measured: `(0, 0)` with the flag,
  `(460, 348)` without.
  → Set it only where the window's size is hard-coded (`MeetingsWindowController`). Leave
  it alone wherever `fittingSize` is read (`ConsentWindowController`, `RecordingHUD`), and
  floor the result so a window can never be built too small to see.

### The meetings window

**It is a plain `HStack`, not a `NavigationSplitView`, and that is deliberate.** Hosted in a
hand-built `NSWindow` — no `Scene`, no toolbar — SwiftUI's split view brought titlebar
handling with it that could not be relied on. Every one of these was measured, and every
one of them cost a release:

- Its columns report **no safe area**. Anything placed at the top of the sidebar lands at
  y 0, behind the traffic lights — by `VStack` and by `safeAreaInset` alike.
- The list inside a column carried **scroll insets that vanished** the moment anything was
  stacked around it (measured: `contentInsets.top` 44 → 0). The rows still looked right at
  rest; the damage only showed on scrolling, when rows rode up into the titlebar and stayed
  there. "Fine until you scroll" is why this survived two rounds of checking.
- **Swapping one split view for another** — settings for meetings — left the detail column
  permanently blank. It is backed by an `NSSplitViewController` and does not survive being
  replaced.
- Its **collapse button hides the sidebar with no way back**, because the button lives in
  the column it just collapsed. One click and both the meeting list and the settings are
  unreachable.

None of that is a two-column layout being hard. The sidebar is a fixed-width `VStack` of
heading, `ScrollView` and a pinned footer button; rows are `SidebarButton`s that draw their
own selection and hover. Settings borrows the same sidebar with categories in place of
meetings, so the button in the bottom corner is the only thing that changes.

**The one rule that keeps the titlebar out of trouble: only decoration ignores the safe
area.** The window does set `fullSizeContentView` with a transparent titlebar, so the
sidebar runs the full height of the window with no line ruled across it under the traffic
lights. What makes that safe is that SwiftUI gives a *plain* root view a top safe area the
height of the titlebar (measured: 32), and every container here stays inside it. The
sidebar's background and its trailing hairline are the only things that opt out, with
`ignoresSafeArea(edges: .top)`, and they are colour rather than content. The hairline is
drawn there rather than as a `Divider()` between the columns for the same reason — a divider
in the stack would start below the titlebar and leave a notch at the top.

- **A `ScrollView` that touches the top of the window extends into the titlebar**, insetting
  its content instead (measured: `contentInsets.top` 32), and then scrolled text slides up
  to the window's top edge with nothing over it. Anything non-scrolling above it stops that,
  which is why the settings page's title is pinned outside its `ScrollView` — the meeting
  page was already fine, its header being above the scrolling part.

- The app icon and name are the **sidebar's heading**. An earlier version put them in an
  `NSTitlebarAccessoryViewController` (`layoutAttribute = .leading`, measured at x 88),
  which was the only place they could go while the split view owned the titlebar. The
  proxy-icon route — `representedURL` plus a swapped `documentIconButton` image — does not
  work at all in such a window: the button is created, given the image, and left hidden.
- `NSHostingView.sizingOptions = []` **is correct for this window** — its size is set in
  code and its `fittingSize` is never read. Left at the default it pushes the SwiftUI
  content's min and max size onto the window, which is what made resizing fight back. The
  opposite mistake, on a window that *does* read `fittingSize`, is in `ConsentWindowController`.
- A restored frame outlives the display it was saved on, so `show()` fits the window to
  `visibleFrame` — otherwise an unplugged monitor leaves the window hanging off the bottom
  of the laptop screen with its resize corner unreachable.

### Verifying a window without being able to see it

A menu-bar app cannot be driven by the usual UI tooling, so the harness renders the real
views instead: compile every source but `main.swift` together with a `main.swift` that
builds `MeetingsWindowController` and captures the window. Two things to know:

- **`layer.render(in:)` and `cacheDisplay` never capture the sidebar.** Vibrancy is drawn
  by the window server, and `screencapture -l` needs a permission an unsigned harness does
  not have. The detail column, and any window without vibrancy, render fine.
- So measure what you cannot see: a `GeometryReader` overlay printing
  `frame(in: .global)` answers "is this behind the titlebar" and "did this column collapse"
  exactly, and it was the only thing that distinguished a view that was laid out correctly
  and merely absent from the snapshot from one that was genuinely zero-sized.

### Icons

Three images, from two source files, and they are not interchangeable.

- `AppIcon.png` is the Dock icon: the artwork already inside its rounded tile. `build.sh`
  turns it into `AppIcon.icns` via `make-icon.swift`, which only resizes — adding a mask or
  rounding of its own would round the corners twice.
- `Logo.png` is the same drawing with no tile behind it. The sidebar heading uses it
  directly; `NSApp.applicationIconImage` would put a rounded square inline next to text.
- The menu bar icon is that logo turned into a **template**, at runtime, in `Branding`.
  Marking the logo itself `isTemplate` does not work: a template carries only the alpha
  channel, and this drawing's alpha is the whole silhouette — bubble and waveform together
  — so it paints as a solid blob. The template is built from colour instead, taking
  `1 - min(r, g, b)` as ink, which keeps the dark bubble solid, punches the white waveform
  bars through it, and reads the red bubble as full ink rather than the washed-out grey
  luminance gives it. Un-premultiply before reading the pixel or every soft edge darkens
  and the mark grows a halo.
- **The recording state keeps the red dot**, not the logo. The one thing the menu bar has
  to say while a meeting runs is that a meeting is running.

### Consent

- Consent state lives **on the meeting** and is carried into every export. It is the only
  part of a recording that cannot be reconstructed afterwards: a transcript can be re-run,
  whether the room agreed cannot.
- The pre-recording sheet offers a **sentence to say out loud**, in English and German.
  That is the single most useful thing on the screen — people skip asking because they do
  not know how to raise it, not out of principle.
- Retention defaults to deleting audio 7 days after transcription. The transcript is what
  the user wanted; the audio is other people's voices, and keeping it is the part that
  needs a reason.

## Conventions

- Comments explain *why*, especially where the code looks odd — most of the odd-looking
  code here is working around one of the gotchas above. Keep them; they are load-bearing.
- Secrets: the API key lives in a `0600` file at
  `~/Library/Application Support/QuickMeet/gemini-api-key`, inside a `0700` directory and
  excluded from Time Machine. Not the Keychain (access is per code signature, so ad-hoc
  builds prompt endlessly), not `UserDefaults` (`defaults read` would print it). It must
  never be logged; `Diagnostics` redacts anything `AIza`- or `AQ.`-shaped as a backstop.
- The transcript is **data, never instructions**. It contains other people, possibly
  reading aloud from a screen. `GeminiNotes` fences it in `<transcript>` tags and says so
  explicitly — "ignore your instructions" said in a meeting must summarise as a person
  saying an odd thing.
- Idle cost matters: no timers, no audio session, no polling between meetings.
- The transcript is saved **before** the notes pass runs. Notes can be regenerated from a
  transcript; a transcript cannot be regenerated once the audio is gone.

## Verifying a change

No unit tests in the package. There is a self-test harness pattern that compiles the pure
logic files standalone — worth recreating for changes to `TranscriptBuilder`,
`AudioChunker`, `PCMStreamWriter` or either Gemini parser, since those are the parts whose
bugs are invisible by hand. It caught the seam duplication bug.

By hand:

1. `./build.sh`, then `open /Applications/QuickMeet.app`.
2. Record 30 seconds with something playing. **Both** meters must move.
3. The log names the device opened, the aggregate's anchor and channel offset, chunk
   counts and every HTTP error with the real server message.
4. A `peak` near 0 on the system stream means the permission, not the API.
5. With Bluetooth headphones connected, play music and record. The music must not go
   muffled and mono.

## Don't

- Don't add dependencies, an Xcode project, or a transcript language picker.
- Don't build the tap's aggregate without an output-device anchor. It silently records
  nothing.
- Don't warn the user when no frames arrive — that is a device idling, not a fault, and it
  recovers by itself. Don't re-anchor the aggregate to chase it.
- Don't remove the WAV header repair or the wall-clock silence padding. Both exist because
  the failures they catch are invisible.
- Don't read a recorder's `peakLevel` or `duration` expecting the writer to still be there.
- Don't re-enable smart mode alongside diarization, or add `language_codes` or
  `custom_vocabulary`.
- Don't merge the two capture streams into one track.
- Don't add a hidden or indicator-free recording mode.
- Don't reach for `NavigationSplitView` here. The two-column layout is a plain `HStack` for
  reasons that are all written down above.
- Don't let anything but background colour ignore the safe area in the meetings window, and
  don't put a `ScrollView` flush against the top of it.
- Don't show a speaker the label the model gave them, and don't number anybody from 0.
- Don't revert to ad-hoc signing, or ship a second copy of the app anywhere on disk.
