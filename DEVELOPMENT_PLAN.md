# Bandstand

## Project Plan — Standalone Chord-Chart Reader, Practice Tool and Backing-Track Engine

**Stack:** Flutter (UI + domain model, Dart) · Rust (audio core, synth, transport) · flutter_rust_bridge (FFI)
**Targets:** Linux, Windows, macOS, Android, iPadOS/iOS. **No web target. No cloud. No collaboration features.**
**Status of this document:** implementation plan and reference map. Written to be consumed by an LLM coding agent working in a local checkout alongside the JJazzLab source tree.

### Name and identifiers

The app is **Bandstand** — the place you play from, and a music stand you read from. Use these strings consistently everywhere; the agent must not invent variants.

| Context | String |
| --- | --- |
| Display name | `Bandstand` |
| Repo / project root | `bandstand` |
| Flutter package (`pubspec.yaml`) | `bandstand` |
| Dart library import root | `package:bandstand/` |
| Rust crates | `bandstand-audio-host`, `bandstand-synth`, `bandstand-sequencer`, `bandstand-transport`, `bandstand-ffi` |
| Android application id | `dev.bandstand` |
| iOS/macOS bundle id | `dev.bandstand` |
| Linux binary / desktop entry | `bandstand` |
| Library folder | `~/Music/Bandstand/` |
| Config folder | `~/.config/bandstand/` (XDG on Linux; platform equivalents elsewhere) |
| Song file extension | `.song.json` |
| Playlist file extension | `.playlist.json` |

Note that `flutter create` derives the application id as `<--org>.<--project-name>`, so the correct invocation is `--org dev --project-name bandstand`, giving `dev.bandstand`. Passing `--org dev.bandstand` would produce `dev.bandstand.bandstand`.

`dev.bandstand` maps to the domain `bandstand.dev`; register it, or swap the prefix, before any public release. Changing it after release forces users to reinstall rather than update.

**Naming diligence, done:** no music or sheet-music app of this name surfaced in app-store or software-directory searches. The live associations are *American Bandstand* (Dick Clark Productions) and the Broadway musical *Bandstand* — different classes, no software conflict. Re-check the app stores and EUIPO/USPTO before any public release, and confirm nothing has appeared in the meantime.

---

## 0. How to use this document

This plan is written for an agent-assisted build. Rules for the agent:

1. **Work milestone by milestone.** Each milestone in §10 has a deliverable and an acceptance test. Do not start milestone N+1 until N's acceptance test passes.
2. **The reference trees are read-only and live outside the repo**, at `/home/vladimir/develop/refs/`. Never edited, never copied verbatim, never committed. See §1 and §14.
   - `/home/vladimir/develop/refs/JJazzLab/` — consult freely, per the discipline in §1.
   - `/home/vladimir/develop/refs/vree/` — **not in scope by default.** Do not grep it, do not read it, unless the current task is the MusicXML importer (§5.2) and the human has said so. Reason: it solves problems this project deliberately does not have, and surfacing it in searches anchors the agent on irrelevant code.
3. **Every domain type gets a unit test before it gets a consumer.** The domain layer is small, pure, and totally testable. Exploit that.
4. **Never put audio logic in Dart. Never put UI logic in Rust.** See §3 for the boundary.
5. **When behaviour is ambiguous, consult the reference implementation, then write down the rule in `docs/rules/` in your own words, then implement from your written rule.** This is both a legal discipline (§1) and a design discipline — it forces you to understand rather than transliterate.

---

## 0.1 Progress

Maintained by the coding agent. A milestone is **done** only when its §10
acceptance test has actually been run and passed — not when the code exists.

| Milestone | Status | Evidence |
| --- | --- | --- |
| M0 — Skeleton | ✅ done on Linux (2026-09-01) and on Android (2026-09-04) | `just check` green; `integration_test/audio_engine_test.dart` — 4/4 passing: opens a real device, renders a 440 Hz tone with zero dropouts, reads the position atomic from Dart, clock drift inside the §3 budget. Benchmarks in `docs/benchmarks.md`. |
| M0.5 — Prove the central bet | **paradigm accepted, quality deferred** (2026-09-01) | `tools/tiling_probe`, 55 tests green. `renders/tiling-probe.mid`. Human verdict: corpus too small and scorer too crude to judge the line on its merits — both are known and expected at this size, both are M6 work. The mechanism itself is not in doubt, so M1 proceeds. Findings in `docs/rules/corpus-tiling.md` §8. |
| M1 — Harmony core | **done** (2026-09-01) | 173 Dart tests green. All three §10 acceptance criteria met and asserted by count: a 2 516-case parser suite, 2 520 transposition cases through all twelve keys with spelling assertions, and `parse(format(x)) == x` over every core type on every root. |
| M2 — Song model, library, playlists | **done** (2026-09-01) | 363 Dart tests green plus 8 integration tests driving the real app on the Linux desktop. All three §10 M2 criteria asserted: 100 songs created/saved/loaded/reordered, 50 undo/redo operations without divergence, playlist overrides proven not to mutate the song. |
| M3 — Chart renderer + editor | **built and verified except the two human judgements** (2026-09-01) | 442 Dart tests plus 11 integration tests on the Linux desktop. The renderer, reading mode, editor and iReal Pro importer are done; §10's "50 imported charts with correct bar counts and structure" passes. "Readable at 2 m" and "edit a 32-bar tune in under 2 minutes" are yours to judge — see below. |
| M4 — Rust synth + transport | ✅ done (2026-09-03) | 210 Rust tests plus 7 integration tests on a real device: an SF2 sampler that plays all 128 General MIDI programs, a sequencer, offline bounce, zero dropouts over a minute at a 256-frame buffer, cursor drift far inside the §3 budget. The A/B against FluidSynth 2.3.4 measures identical note onsets, 0.997 envelope correlation, +0.8 dB level and matching crest factor. The listening judgement of §15 is still the human's. |
| M5 — Drums + mixer | **done** (2026-09-03) | 517 Dart tests plus 6 integration tests on a real device. Both §10 M5 criteria pass: an imported iReal chart generates drums and plays through the engine with zero dropouts, and regeneration after a chord edit takes ~1 ms against a 100 ms budget. |
| M6 — Walking bass via corpus tiling | **built and measured; the listening test is yours** (2026-09-03) | 652 Dart tests plus 18 for the import tool. Corpus format (ADR 0008) and importer; 67 phrases over 16 root profiles; transposibility, deep join scoring, tempo sensitivity, cached partial scores, two tilers. Three choruses of an AABA: 17 distinct phrases, mean placement score 0.90, widest join 10 semitones, no gaps, 4 ms for 192 bars. §10's acceptance is a blind listening test — not mine to take (§15). Files to listen to: `build/audition/`. |
| M7 — Comping, voicings, practice | ✅ done (2026-09-03) | 733 Dart tests plus 33 integration tests on a real device. Both §10 M7 criteria pass: a voicing suite over all twelve keys asserts no root doubling, no voice moving 4 semitones or more, and no interval clashes; a tempo ramp is exact at the fortieth chorus of a twenty-minute session. Voicing engine with guide-tone leading and a seed search, 20 comping cells, practice session with ramp, key cycling and loop, and a practice screen. |
| M8 — Mobile hardening | 🟡 three of §10's four acceptance parts taken (2026-09-04) | 746 Dart tests, 219 Rust tests, 43 integration tests. Android audio (JNI context ADR 0009, focus, foreground service, wake lock, 16 KB alignment); sample streaming measured — a 148 MB bank costs 2–4 MB resident, a warmed preset 8.6 MB, a release APK 75 MB PSS against a 250 MB budget; 77 chord shapes each verified to sound its chord; scale hints; Nashville numbers; page-turner input. The M0 Android leg is closed. §10's 90-minute set **passed** on the emulator — 270 checks, 404 screen locks, 0 dropouts. Left: battery drain, which needs a real device. |
| M9 — Export, polish, optional extras | 🟡 exporters, importers and the test infrastructure (2026-09-05) | MIDI (multi-track, markers per song part), audio (through the same synth as playback), MusicXML (the written page, repeats intact), PDF (the chart painter rastered at 300 dpi — ADR 0010). Reachable from the song screen. §5.2's importers are now complete: MusicXML (165-file suite, no file breaks it) and the plain text lead sheet, both routed by content rather than by asking. §11.3's `benchmarks/` suite is built and every §3 budget is measured — which found and fixed a quadratic chart layout. §11.2's audio null test is built. §11.1's JJazzLab oracle is blocked on a toolchain decision that is yours, assessed in full there. Nashville numbers now reach the chart, which is the only place §9's case for them applies. Left: the optional extras — melody display, literal part playback, self-recording. |

### M3 — what was built

- [x] `docs/rules/chart-layout.md` and `docs/rules/ireal-format.md`, written before the code.
- [x] `app/lib/render/` — a layout engine that is pure geometry (no colours, no selection, no playback), a `CustomPainter` for the chart and a second one for the cursor, and a `ChartView` that reflows to whatever width it is given. 30 layout tests and 5 golden images.
- [x] **Bars per line follow §8.1**: the density preference, reduced until bars are wide enough to read — the type never shrinks. A section never starts mid-line, and a short section makes a short line rather than stretched bars.
- [x] Repeats, endings with explicit spans, segno/coda/fine/D.C./D.S., pickup bars, meter changes, annotations and bar numbers all draw.
- [x] Reading mode: full screen, largest type, tap zones only at the far edges, a transport overlay that hides itself, wake lock on, and the cursor driven by the **real M0 transport** through the flattened→written bar map.
- [x] Chart editor: an always-focused chord field with auto-advance (type `Dm7`, enter, next bar), arrow-key navigation, a tab-toggled half-bar step, tap-to-place, and buttons for sections, repeats, endings, marks and bar insertion — every one a `Command`, so every one undoes.
- [x] **iReal Pro importer** (§5.2) — the whole `irealbook://` grammar: bars, repeats, numbered endings, sections including intro and verse, meters, segno and coda, bar repeats, holds, `N.C.`, slash chords, annotations, alternate chords and every filler token. Plus an import dialog that reads the clipboard and reports what it could not read.
- [x] §10's first acceptance criterion: `test/io/importers/ireal_corpus_test.dart` imports 50 charts and asserts bar counts, resolved forms, flattening, and layout at four widths with nothing off the page.

Three real defects the tests and goldens caught, all fixed:

- Chords collided with the repeat barline dots — visible the moment the first golden was rendered.
- The "keep the last chord on the page" clamp could push a chord left of the one before it, overlapping them.
- **The navigation resolver looped forever** on a chart with three ending brackets and a two-pass repeat: having played the bracket for this pass, it walked into a later one and jumped backwards. Found by the 50-chart corpus, not by the unit tests.

#### M3's two remaining criteria are yours

§10 M3 asks for three things. The first is done and asserted. The other two are
judgements a test cannot make:

1. **"Readable at 2 m on the tablet."** §8.1 is explicit that this is tested by
   putting the tablet on a stand and stepping back, not by looking at it on a
   desk. `ChartStyle.reading` starts at a 46-point chord and everything else
   scales from it; if that is wrong, it is one number.
2. **"Edit a 32-bar tune in under 2 minutes."** The mechanical path is one
   keystroke sequence per bar — type the chord, press enter, the caret moves on
   — but whether that adds up to two minutes is something only you can time.

#### Known gap: `irealb://`

Modern iReal Pro exports use `irealb://`, whose body is scrambled. The algorithm
is published in the four implementations §5.2 names, none of which is in the
local reference tree, and it is **not implemented from memory**: an unscrambler
that is subtly wrong does not fail, it produces a chart that reads plausibly and
is the wrong tune. `docs/rules/ireal-format.md` §7 says what finishing it takes.
Until then the importer reads `irealbook://` and says so plainly for the other.

### §5.2 — the importers, completed (2026-09-05)

The priority order of §5.2 is now done through item 4. Both new importers are
reachable from the same dialogue, **routed by content rather than by asking**:
an iReal URL announces itself with its scheme, MusicXML with its document
element, and anything else with bar lines in it is a typed chart. Making the
user choose would be asking them for something the computer can see.

- [x] **1. iReal Pro** — done at M3.
- [x] **2. MusicXML** — `docs/rules/musicxml-import.md`, **ADR 0011**.
  Harmony, bars, meter, key, repeats, endings, navigation marks, rehearsal
  marks, title, composer and tempo. Roots keep their spelling; a `<kind>` with
  a `text` attribute wins over the fixed vocabulary, which is what round-trips
  Bandstand's own export and what keeps `7alt` from flattening to `dominant`.
  Reads `.mxl` archives, and falls back to Latin-1 for the files that declare
  UTF-8 and are not.
  **Acceptance taken**: §5.2 names the Unofficial MusicXML Test Suite, and all
  **165 files** import without breaking the parser, at **0.7 ms each**. Fetched
  rather than vendored — `just fetch-musicxml-suite` — the same discipline as
  the soundfont; the tests skip with a message when it is absent.
  A timewise score is *refused with a reason* rather than importing as an empty
  chart, and a score with no harmony still yields its bars and says why.
- [x] **3. Plain text lead sheet** — `docs/rules/text-import.md`.
  `| Dm7 | G7 | Cmaj7 |`, optional headers, sections, `|:` `:|x3`, `|1.` `|2.`,
  `%` for a repeated bar and `/` for a held beat. Chords divide a bar evenly,
  which is the convention every chart in this notation uses. A bad chord names
  its line and **parsing continues** — a typo in bar 30 must not lose bars 1
  to 29.
- [x] **4. MIDI import** for the phrase corpus — done at M6, as
  `tools/corpus_import`.
- [ ] 5. JJazzLab `.sng`, which §5.2 marks optional and worth it only if there
  are existing arrangements to rescue.

**One dependency added**, `xml`, with ADR 0011. Writing XML by hand is a
hundred lines; reading it correctly is entities, encodings, namespaces, CDATA
and a DOCTYPE with an external subset — every one of which is a file that fails
to import for a reason the user cannot see. §15 prefers owning the stack; it
does not prefer owning XML.

Two faults found while building these, both real:

1. **`TimeSignature`'s constructor documents a throw and performs an assert.**
   It is `const`, so it cannot throw — and an assert is *stripped in release*,
   which means `TimeSignature(4, 5)` from a user's file would have been
   accepted in the shipping app and rejected only in a test. The importer now
   goes through `tryParse`, which validates and returns null, and the
   constructor's documentation says what it actually does.
2. **Two consecutive bar lines lost the empty bar between them.** `| C | | Am |`
   read as two bars, because the parser consumed each `|` as a separator
   before ever looking between them. Rewritten to find the markers first and
   take the text between — an empty bar is a real thing that sounds as the one
   before it.

---

### M9 — what was built

The four exporters of §5.3, per `docs/rules/exporters.md`. The distinction the
document turns on is that **MIDI and audio export what Bandstand *played*, and
PDF and MusicXML export what the player *wrote*** — a tune whose bass line is
rerolled has a different MIDI export and an identical PDF one.

- [x] **MIDI** (§2) — format 1, a conductor track carrying the tempo, the meter
  and a **marker per song part**, then one named track per voice with its patch
  at the top. §5.3 asks for the markers by name and they are what makes an
  exported file navigable in a DAW rather than four minutes of undifferentiated
  notes. Byte-identical for the same song and seed, which is §11.2's
  determinism test applied at the boundary.
- [x] **Audio** — the offline renderer of M4, in front of a destination. It
  renders through the same synth as playback, so what is exported is what was
  heard.
- [x] **MusicXML** (§5) — a measure per **written** bar, chords as `<harmony>`,
  sections as rehearsal marks, and repeats as repeats rather than as the bars
  they expand to. Roots are *spelled*: B♭ is `<root-step>B</root-step>` with an
  alter of −1, and writing A♯ would be wrong in exactly the way
  `docs/rules/pitch-and-spelling.md` exists to prevent. A quality MusicXML has
  no `kind` for keeps its own symbol in the `text` attribute, so nothing is
  silently renamed.
- [x] **PDF** (§4) — **ADR 0010**. The chart painter, at 300 dpi, embedded as an
  image. The *layout* is genuinely shared, which is what §8.1 chose a painter
  for: `ChartLayoutEngine` reflows to A4 exactly as it reflows to a phone, so
  the page is a typeset chart rather than a screenshot. A vector adapter over
  the `pdf` package's graphics was rejected — implementing Flutter's `Canvas`,
  `drawParagraph` and all, is a large surface whose every gap is a chart that
  prints subtly wrong, against a file a few hundred kilobytes larger.
  Added `ChartStyle.printed()`, which takes no `ColorScheme` because paper has
  none: a dark-theme chart rendered to PDF would be a page of ink.
- [x] **One place for the files** (§6): `<library>/exports/`, written
  atomically like everything else that touches the library folder (§5.4), with
  the path returned so the UI can say where it went. An export the user cannot
  find has not happened. Titles are reduced to something every filesystem
  accepts — `A/B Blues` is a path that lands somewhere unexpected.
- [x] Reachable from the song screen, as a menu with one tap per format.

**One dependency added**, `pdf`, with ADR 0010. It forced `archive` down from
^4.2.0 to ^4.0.9, which the library's zip import/export still compiles and
passes against. `printing` was deliberately *not* added: it is the
platform-channel half — print dialogues and printer discovery — and Bandstand
writes a file that the platform's own viewer opens.

---

### M8 — what was built

Android audio, verified on an `sdk_gphone16k_x86_64` emulator, API 37. Rules:
`docs/rules/android-audio.md`. Architecture: **ADR 0009**.

- [x] **The JNI context** (§1). Oboe asks `ndk_context` for a `JavaVM` and a
  `Context`; a Flutter app supplies neither, so every attempt to open a device
  on Android died with `PanicException(android context was not initialized)`.
  Kotlin now hands the **application** context — not an activity's, which is
  destroyed on rotation — to one JNI entry point, which promotes it to a global
  reference and installs it once. Idempotent, because `onCreate` runs again
  after a configuration change and `initialize_android_context` *asserts* it
  has not been called before.
- [x] **Audio focus** (§2), with the policy that a permanent loss stops, a
  transient loss pauses and resumes, and a duckable loss ducks without pausing
  — so the cursor stays where the player is looking. Resume is only automatic
  after a pause *Bandstand* caused.
- [x] **The foreground service** (§3), typed `mediaPlayback`, with a
  notification channel, a stop action and a partial wake lock. Started by the
  transport starting, not by the app opening.
- [x] **One place playback starts.** Every UI path now goes through
  `PlatformAudioController.play`, so the platform handshake cannot be
  remembered in one screen and forgotten in another, and a refused focus
  request stops the band *before* it sounds.
- [x] **16 KB page alignment** (§5), verified rather than assumed by
  `just android-check`. 64-bit only: a 16 KB device runs no 32-bit code, so
  `armeabi-v7a` at 4 KB is correct and the check says so.
- [x] **`just android-test`**, which pushes a General MIDI bank to the device
  first. Without one the sampler suites skipped — so the sampler, the part most
  likely to differ on another architecture, was not exercised on Android at
  all. It now runs a full minute of playback there with zero dropouts.

Four real faults the emulator found, none of them visible on a desktop:

1. **A nonsense audio timestamp, and then an unstable one.** cpal's Android
   backend reported a playback instant **1148 seconds** after the callback,
   which put the published playhead nineteen minutes into the future and left
   the cursor pinned to whatever `Playhead.resolve` clamps at. Bounding the
   reported latency by what the buffer could physically hold fixed the
   magnitude — and exposed the real problem, which was that the figure *varied*
   between blocks, so the published host time jumped and ran backwards by most
   of a second. Output latency is a property of the stream, not of the moment,
   so it is now measured once and kept: a constant error shifts the cursor,
   where a varying one makes it jitter, and §3 budgets drift rather than offset.
2. **Two UI overflows**, at 74 px and 18 px, on the first phone-sized screen the
   app had ever been laid out on. A `Row` of three buttons became a `Wrap`, and
   a device dropdown got `isExpanded` so its ellipsis works.
3. **A third `LinearProgressIndicator` blocking `pumpAndSettle`** — the same
   trap as the M0 ticker and the M6 rhythm picker, this time in the device list.
4. **Three integration tests were measuring the desktop's buffer size rather
   than Bandstand.** A transport command lands at the top of the next audio
   block, and the gap between blocks is a device property: microseconds on a
   desktop, 727 ms on the emulator. Fixed waits sampled readings that were still
   extrapolating; the tests now wait for the state the command asked for.
   Likewise "no dropouts at a 256-frame buffer" asserted the buffer *was* 256,
   which tests Android's willingness to honour a request rather than anything
   of ours — the dropout count is now asserted unconditionally and the buffer
   size only where a real-time backend granted it.

And one thing that cannot be verified here, stated rather than papered over:

- [ ] **§3's clock-drift budget needs real hardware.** 20 ms over 5 minutes is
  0.0067%, the order of crystal drift. The emulator negotiates a 34 880-frame
  buffer, delivers it in bursts — 358 ms of music arriving 13 ms after the
  previous callback — and its software audio clock was measured drifting
  **0.53% over thirty seconds**, eighty times the budget. Nothing in the app can
  fix that and no number from it would mean anything, so the two clock tests
  skip on a device whose buffer is over 8192 frames and say why. They run
  unskipped on Linux.

### The reference features (§9), and sample streaming

- [x] **Sample streaming is measured, not assumed.** §7.2 says *"a full bank
  cannot be resident"* and ADR 0007 answered with `mmap`; M8 is where that claim
  was finally tested. Loading a **148 MB** bank grows the process by **4.0 MB**
  on Linux and **2.3 MB** on Android. A release APK sits at **75 MB PSS /
  183 MB RSS** against the 250 MB tablet budget.
- [x] **The warming pass ADR 0007 promised, and M5 did not deliver.** Mapping
  the samples means a page fault can land on the audio thread, and the audible
  symptom is a click on the first note of a newly chosen sound — on stage, the
  worst possible moment. `SoundBank::warm_preset` walks a preset's zones to its
  samples and touches one byte per page, on the **control thread**, when a
  sequence loads. Measured at **8.6 MB for one preset** against a 148 MB bank,
  which is what makes it affordable and prefaulting the file the wrong answer.
  Rules: `docs/rules/sf2-sampler.md` §9.
- [x] **Chord diagrams** — `docs/rules/chord-diagrams.md`,
  `docs/format/chord-diagrams.md`. 77 shapes across guitar, ukulele and bass,
  and **every one is checked to sound the chord it claims**: the pitch each
  string produces is computed from the tuning and the frets, and the pitch
  classes must be exactly the chord's. That check found real errors in a dozen
  hand-entered shapes, which is the one fault a reader cannot see and a player
  finds on stage. A movable shape names *which string carries its root* —
  inferring it from the lowest played string is wrong for every rootless or
  inverted shape.
- [x] **Scale hints**, on the same screen: the three scales that fit each chord,
  from the library M1 already built.
- [x] **Nashville numbers** — `Nashville.format`. §9 said they *"fall out of the
  degree model almost free"*, and they do. Asserted by the property that
  matters: transposing a tune does not change its numbers, in all twelve keys.
  Added `KeySignature.transposed` on the way, which the practice screen had been
  working around by transposing a whole song to read one key off it.
  **Extended in M9 to the chart itself** — see `docs/rules/chart-layout.md` §6b.
  The numbers existed here but only the chord reference screen showed them, and
  a lookup table is not what the system is for: §9's own case for it is *"playing
  a tune in a key nobody wrote it in"*, which happens on the stand with the chart
  in front of you. Reading mode now toggles between letters and numbers.
- [x] **Page-turner input** — `docs/rules/page-turner.md`. A pedal is a
  Bluetooth keyboard with two keys on it, so it is handled where keyboards are:
  all four conventions (arrows, page, space, AirTurn) turn pages in reading
  mode, and nothing else. Deliberately **not** transport control — a pedal that
  started the band would start it when a player shifted their weight.

### §10's acceptance, without a tablet

*"A 90-minute set on the tablet, screen locked and unlocked repeatedly, no audio
interruption, battery drain acceptable."* Four parts, and only one of them
actually needs the tablet:

| Part | Taken |
| --- | --- |
| 90 minutes of continuous playback | ✅ **taken, 2026-09-04** |
| Screen locked and unlocked repeatedly | ✅ **taken** — 404 locks, 134 unlocks |
| No audio interruption | ✅ **taken** — 24 739 blocks, **0 dropouts** |
| Battery drain acceptable | ❌ **needs real hardware** |

**The run:** `just soak 90 20`, on an `sdk_gphone16k_x86_64` emulator, API 37.
90 minutes 3 seconds, 270 checks twenty seconds apart, **every one clean**: the
transport playing, the playhead advanced (loop wraps counted), audio blocks
still arriving, dropout counter at zero. The set looped a 32-bar form
throughout, and the screen was locked or unlocked 538 times between them.

That is three of §10's four parts met. The foreground service does what it was
built for.

- [x] **`integration_test/soak_test.dart`**, driven by `just soak`. The screen
  is cycled from the host, because an app cannot lock its own screen and the
  test runs on the device where `adb` does not exist. The app then counts its
  own `paused`/`resumed` transitions, so a soak that never saw the screen lock
  **fails** rather than passing quietly — trusting the host loop ran would have
  been the easy mistake.
  It does not idle: it cycles every twenty seconds, because thirty lock/unlock
  transitions prove far more about the foreground service than five thousand
  seconds of nothing happening.
- [ ] **Battery drain.** Not measurable on an emulator and not guessable. The
  partial wake lock is bounded at two hours (§4) so a bug cannot flatten a
  battery overnight, but what a 90-minute set actually costs is a number only a
  device can give.

Two things the soak caught, both mine:

1. **The playhead legitimately goes backwards.** The set loops, so asserting
   `tick > lastTick` failed at the first wrap on a transport that was working
   perfectly. `TransportPosition.loopGeneration` exists for exactly this and is
   now what the assertion uses.
2. A Riverpod `Notifier` constructed directly in the teardown, which only has
   state inside a container — the same slip as in `platform_audio_test`.

### Found while finishing M8, and not a Bandstand fault

- [ ] **This machine's PipeWire is starving its ALSA clients**, so the two
  suites that measure the transport against real time (`audio_engine`,
  `synth`) cannot pass here at present. Measured rather than guessed: with a
  256-frame buffer the stream should take about **187 blocks a second**, and it
  takes **32** — 17% of real time, with the backend reporting zero dropouts.
  Isolated to the environment three ways: it reproduces with every change in
  this milestone reverted; it reproduces with the pre-M8 audio host; and asking
  cpal for the raw `HDA Intel PCH` device instead of `default` or `pipewire`
  restores the block rate immediately. `pipewire` has been up for over an hour
  and is logging `invalid global` errors. The same suites passed repeatedly on
  this machine earlier in the day.
  Nothing in the app can fix a starved device and no timing figure from one
  means anything. Restarting the user's audio stack is their call, not the
  agent's. **Re-run `just integration-test` once the audio server is healthy.**

---

### M7 — what was built

Acceptance (§10 M7), by `test/domain/generation/voicing/voicing_engine_test.dart`
and `test/domain/song/practice_session_test.dart`:

- [x] **No root doubling in rootless voicings.** Asserted over four qualities in
  all twelve keys.
- [x] **Voice movement under 4 semitones between successive chords.** Asserted
  over a ii-V-I in all twelve keys, taken round the cycle of fourths, with every
  join measured.
- [x] **No interval clashes.** No minor ninth between *any* two voices, no
  doubled pitch class, and no interval below its low limit — over nine chord
  qualities in all twelve keys.
- [x] **Tempo ramp works over a 20-minute session.** Fifty choruses, exact at
  the fortieth: a plan is computed from the chorus index rather than
  accumulated, so a session cannot drift.

Built:

- [x] `docs/rules/voicings.md`, `docs/rules/comping.md`, `docs/rules/practice.md`
  — the prose first, per §15.
- [x] **The voicing engine**: five families, guide tones as the skeleton, the
  standard low-interval-limit table, and voice leading that caps the largest
  single move rather than only the total.
- [x] **The comping generator**: 20 rhythmic cells as data, placed against the
  chord spans with the same freshness rule as the drums and the bass, with
  anticipation resolved at the onset rather than baked into the cell.
- [x] **The practice session**: tempo ramp with a ceiling and a floor, key
  cycling by fourths or chromatically, loop ranges clamped rather than wrapped,
  and a **practice screen** to drive them. A key change regenerates rather than
  transposing the notes — the bass register band is absolute, so transposing
  walks the line out of it.
- [x] `EnsembleGenerator` extended to a trio, plus a bass-and-drums rhythm
  section for practising without the piano.

Three things found by measurement, each a real fault rather than a preference:

1. **Two rootless inversions are not enough.** The textbook names type A (third
   at the bottom) and type B (seventh), and alternating them handles a ii-V
   beautifully — one voice moving one semitone. It cannot handle a I-VI: from
   `Cmaj7` as `E G B D` into `A7`, neither named form gets a voice below four
   semitones, which breaks the acceptance on a plain turnaround. The inversion
   starting on the *fifth* holds three voices still and moves D to C#. The
   engine now offers three of the four rotations, dropping only the one that
   puts the ninth under the third.
2. **The dominant needs both its sets.** `3 13 7 9` is the colourful one the
   textbooks lead with; `3 5 7 9` is what leads. Offering only the first was
   half of the same turnaround failure.
3. **A greedy chain is only as good as its seed.** Voicing chord by chord from
   a first voicing chosen on register alone breaks the movement cap on
   `Gm7 | C7 | Fmaj7` — an ordinary ii-V-I in F. `voiceSequence` now tries every
   candidate for the first chord as a seed and keeps the best chain. It is the
   reason comping costs 55 ms against the bass's 4.4 for the same 192 bars, and
   it is worth it: without it the acceptance criterion simply fails.

And one bug in older code, caught by a new test:

- [x] **Humanisation was independent, not correlated.** §6.6 asks for
  *"timing and velocity jitter with correlated, not independent, noise"*, and
  the random walk advanced per note. For drums that is invisible; for a
  four-note voicing it turns every chord into an arpeggio. The walk now advances
  once per onset and every note sharing it moves together, while velocity still
  varies per note — a pianist does not strike four keys with identical force.
  Regression test in `test/domain/generation/post_processing_test.dart`.

---

### M6 — what was built

Acceptance (§10 M6):

- [x] **Does not repeat audibly over 3 choruses — measured.** Three choruses of a
  32-bar AABA, 96 bars, 27 placements: **17 distinct source phrases**, mean
  placement score **0.90**, widest join **10 semitones**, **no** bars falling
  back. `wbp_tiling_test.dart` asserts each of these, and that no phrase recurs
  inside the freshness window at all.
- [ ] **Blind listening test — yours to take (§15).** *"indistinguishable from a
  competent human transcription to you"* is a judgement the agent cannot make.
  `just audition` writes the line to MIDI and renders it; two files are already
  in `build/audition/` (git-ignored): a ii-V-I and the AABA above, each three
  choruses at 160 bpm.

Built:

- [x] `docs/rules/corpus-tiling.md` rewritten as the production spec. §§1–6 are
  what the M0.5 probe established; §§7–11 are what M6 adds, each traceable to
  something the probe found (§12).
- [x] `docs/format/bass-corpus.md` and **ADR 0008** — the corpus is JSON, and
  MIDI is an import source rather than a runtime one.
- [x] **`WbpSource`** (§2): a 1–4 bar phrase with its harmony, deriving root
  profile, extremes, playability, harmonic fit and a per-root transposibility
  map once, at load.
- [x] **`RootProfile`** (§2): harmony reduced to what survives transposition, so
  `Dm7 | G7` and `Fm7 | Bb7` are one shape. Matching is exact, never fuzzy.
- [x] **Deep join scoring** (§7) — the substance of M6 over M0.5. The seam is
  scored on four terms across two notes either side: the interval itself,
  contour continuity, approach quality into the target root, and how the
  incoming phrase lands.
- [x] **Tempo sensitivity** (§9): the penalty on a wide join is scaled by
  tempo, and a phrase may declare the band it belongs in.
- [x] **Cached partial scores** (§10): harmonic fit and register computed once
  per phrase at load, joins memoised for the life of a tiling run. This is what
  makes running two tilers affordable.
- [x] **Two tilers** (§11): longest-first-without-repetition, and
  maximum-distance-between-reuses.
- [x] **A shippable failure mode** (§11): a chord the corpus cannot cover
  becomes a deliberately dull root-and-fifth bar plus a line in
  `GeneratedSong.problems`, rather than an exception. The probe threw; a
  generator that throws when a user plays an unusual chord is not shippable.
- [x] **The corpus**: 67 phrases over 16 root profiles, every one starting on
  the root, ending on a chord tone, and reachable at all twelve roots — asserted
  by `bass_corpus_test.dart`, which also checks the segmentations a standard
  form actually asks for (M0.5 finding 3).
- [x] **`tools/corpus_import`** (§6.4, §12): takes a MIDI take plus a chord
  annotation, harvests every 1-, 2- and 4-bar window that satisfies §5, reports
  what it rejected and why, and merges into the shipped corpus. Proved on a
  12-bar blues take: 10 phrases across 7 profiles.
- [x] **`audition`**: runs the real generator over any form and writes MIDI, so
  the listening test is taken on what the app plays.
- [x] **`EnsembleGenerator`**: a `SongPart` names one `rhythmId`, so without a
  composite a song could play drums *or* bass but never a band. Voices must not
  collide, parameters are namespaced (`drums.intensity` vs
  `walking-bass.intensity`), and each member's seed is mixed with its own id so
  changing the drums does not reroll the bass.
- [x] **A rhythm picker** on the song screen, and `SongCommands.setRhythm` —
  distinct from `rebuildStructure`, which throws the arrangement away. Without
  a way to select the bass, the acceptance could not be taken at all.

Two things worth recording, because both were found by measurement and neither
was visible from the rules alone:

1. **Ranking two tilings on mean score picks the one that repeats.** The
   smooth tiler scored 0.931 using ten phrases where the varied one scored 0.915
   using eighteen — and the generator, comparing mean scores, chose the ten.
   §10 of this plan asks for a line that does not repeat over three choruses,
   which is a property of the whole tiling and invisible to any per-placement
   score: when the form repeats, the best phrase at bar 1 is still the best
   phrase at bar 33. `Tiling.quality` now subtracts a repetition penalty, and
   the varied tiling wins.
2. **A wide leap cannot be left to the blended score.** A 14-semitone join
   scores 0.05 on §7.1's interval term, but full marks on contour, approach and
   landing drag the blend to 0.65 — clear of the seam floor with room to spare.
   §4.2 is not ambiguous about what that interval sounds like, so it is now a
   constraint (`maximumJoinInterval`) and not a score. On the shipped corpus
   that is the difference between a widest join of 14 and one of 9.

Carried forward from M0.5, and now closed:

- [x] Corpus size and shape — 67 phrases against the 50 §6.4 asks for, and
  shaped to the segmentations rather than to common progressions.
- [x] Scorer depth — pre- and post-target scoring across several notes, tempo
  sensitivity, cached partial scores.
- [x] Register handling — a phrase whose only in-range octave forces a bad seam
  is now rejected (§5 constraint 4), which was M0.5 finding 4.

Found while verifying the `just` recipes, and **partly fixed**:

- [x] **`library_test.dart` raced the disk.** `ensureVisible` on a set-entry row
  that had not been read back yet threw "Bad state: No element". `pumpAndSettle`
  returns as soon as no frame is scheduled, which can be before a
  filesystem-backed future completes — the caveat that file opens with. Fixed
  with a `pumpUntil` helper that waits on the widget rather than on a guessed
  delay.
- [x] **The M6 rhythm picker hung `pumpAndSettle`.** Its loading state used an
  indeterminate `LinearProgressIndicator`, which animates forever, so it
  schedules a frame forever. The same failure mode as the free-running `Ticker`
  in M0. Replaced with a static label.
- [x] **The clock-drift test measured the wrong thing.** It timed from the
  moment `transportPlay()` returned, but playback begins when the audio thread
  next takes a block — so the figure carried a constant start-up offset of a
  buffer or more on top of any real drift. On a loaded machine that offset alone
  reached 47 ms against a 20 ms budget and failed a test that says nothing about
  the clock. §3 budgets drift as a *rate* ("under 20 ms over 5 minutes"), so the
  test now measures the change in ticks against the change in wall time between
  two readings, and the offset cancels. Nine consecutive runs green afterwards,
  three of them with the full unit suite running concurrently — the load that
  used to break it.
- [ ] **One uncaptured failure remains.** A `synth` suite failure in one of
  three back-to-back loop passes, whose log was overwritten by the pass that
  followed before it could be read. `just integration-test` now keeps failing
  logs under `build/integration-logs/FAILED-<suite>-<timestamp>.log` rather than
  letting the next run clobber them, so the next occurrence will be
  diagnosable. Everything else has been green since: several clean loop passes,
  and the whole suite green on the last three runs. **Confirm it is gone before
  trusting the suite in a pre-commit hook.**

Still open, and honestly a corpus problem rather than a code one: the corpus is
**programmed, not played**. §6.4 is emphatic that recording your own is the
highest-value work in the project, and every phrase here was typed. The
machinery to replace them exists — record a take, run `just corpus-import`, and
the phrases are yours.

---

### M5 — what was built

Acceptance (§10 M5), by `integration_test/generation_test.dart`:

- [x] **Press play on an imported chart and hear time.** An `irealbook://` URL imports, generates drums, loads into the engine and plays through a real device with the dropout counter at zero.
- [x] **Regeneration after a chord edit under 200 ms.** Measured at **1.2 ms** for a 32-bar song and **7 ms** for 192 bars, against §3's 100 ms target and 300 ms limit.

The phrase model (§4.2) and the pipeline (§6.1), at `app/lib/domain/`:

- [x] `docs/rules/generation-pipeline.md` and `docs/rules/drum-generation.md`, written before the code.
- [x] `FloatRange`, `NoteEvent`, `Phrase`, `SizedPhrase` — immutable, always sorted, with client properties for the tags a generator attaches while working. A drum phrase refuses to transpose, because its pitches are instruments.
- [x] `MusicGenerator`, `GenerationContext` with an **explicit seed** threaded through (§6.2), and `SongGenerator` running the whole pipeline over a flattened song.
- [x] The **post-processing chain in the order §6.1 specifies**: range clamp, overlap fix, accents, anticipation, humanise, velocity shaping. Humanising is a random walk with a pull to centre, so a player who drags stays dragging for a few notes — correlated noise, as §6.6 asks, not the alternating jitter that sounds like a fault.
- [x] `DrumGenerator` with **11 patterns as data** in `app/assets/drum_patterns.json`: swing, brushes, bossa, straight eighths, a jazz waltz, fills and endings. Hits carry a probability, so the same pattern comes out slightly different each time round — deterministically, from the seed.
- [x] Fills at section boundaries and every eight bars, an ending on the last bar of the last part, and a density arc across the song (§6.6).
- [x] The mixer screen (§8.2): per-voice volume, pan, mute, solo and instrument, edited through the command stack so it is undoable and saved with the tune.

Three bugs the tests caught:

- **`SizedPhrase.shifted` moved the notes but not the span**, and the constructor drops notes outside the span — so every song part after the first was silently discarded. The song played its first sixteen bars and then nothing.
- **A two-bar groove stepped straight over the bar a fill or an ending was due in**, so a form whose fills fell on odd bars never got one.
- **The domain imported from `io/`**, which the purity test missed because the import was relative (`../../io/...`) rather than by package. The test now catches both roads.

### M4 — what was built

Acceptance (§10 M4), measured on the Linux desktop by
`integration_test/synth_test.dart`:

- [x] **Plays a General MIDI file.** A soundbank loads, a sequence loads, and the transport drives both through a real device.
- [x] **A/B against FluidSynth.** `rust/tests/fluidsynth_ab_test.rs`, against FluidSynth 2.3.4. Rules and tolerances: `docs/rules/sf2-sampler.md` §8. Four bars of piano at 120 bpm through both, at 48 kHz:

  | Measure | Bandstand | FluidSynth |
  | --- | --- | --- |
  | Note onsets (10 ms windows) | 0, 200, 400, 600 | 0, 200, 400, 600 |
  | Loudness envelope | correlation 0.997 | |
  | RMS at the calibrated gains | 0.00810 | 0.00739 (+0.8 dB) |
  | Crest factor | 18.6 dB | 18.5 dB |
  | Energy above vs below 2 kHz | 0.0615 | 0.0634 (0.97x) |
  | Peak | 0.0690, no clipping | 0.0625 |

  The one thing that looked like a fault was not one. Compared at the same
  nominal gain the two are 7.2 dB apart, but FluidSynth's gain is exactly linear
  (0.25, 0.5, 1.0 give doublings) and our `master_gain` 0.5 sits at its 0.219 —
  the gap is a difference of convention, not of level. At `master_gain` 0.5
  against FluidSynth's default `-g 0.2` they agree to within a decibel, and that
  is where the test now compares, within 3 dB rather than 12.

  The tests skip when `fluidsynth` or a General MIDI bank is absent.

- [ ] **Listen to the A/B — the human's call (§15).** The measurements above say
  the two renders have the same shape; whether ours has *no audible defects* is
  a listening judgement, not mine to make. Both files are written by
  `BANDSTAND_AB_DIR=build/ab cargo test --test fluidsynth_ab_test write_the_pair -- --ignored --nocapture`
  and currently sit in `build/ab/` (git-ignored) as `ab-bandstand.wav` and
  `ab-fluidsynth.wav`.
- [x] **Cursor drift inside the §3 budget.** Measured end to end through the FFI over ten seconds; the transport's own test simulates five minutes and asserts under 10 ms.
- [x] **No dropouts at a 256-frame buffer** — verified over a minute of continuous playing, with the backend's error counter asserted at zero. An hour is a soak test, not a suite test; the counter that would catch it is on the audio-engine screen.

The audio core (`rust/`):

- [x] `docs/rules/sf2-sampler.md` — the format, the zone model, every unit conversion, the voice pipeline, the stealing policy. Written before the code.
- [x] **SoundFont reader** — RIFF container, the nine `pdta` arrays, global zones, and the preset-offsets-instrument-absolutes rule that catches everyone. Verified against a real 6 MB General MIDI bank: all 128 programs present, every zone and sample in range, every program sounds at middle C, every looping sample's points usable.
- [x] **Sampler** — cubic interpolation, DAHDSR volume and modulation envelopes, a resonant low-pass, two LFOs, equal-power pan, exclusive classes, and a capped voice pool that steals finished, then oldest-released, then quietest.
- [x] **Samples are memory-mapped** (ADR 0007), so the OS page cache is the LRU and a 1 GB bank does not have to be resident — the §3 mobile budget decided before the sampler was written, as §7.2 insists.
- [x] **Effects** — a Freeverb-class reverb and a three-tap chorus, on a bus rather than per voice.
- [x] `bandstand-sequencer` — a sorted event list, sample-accurate placement inside a block, program changes restored on a seek, and **every sounding note released at a loop wrap**, which is what stops a loop leaving notes hanging (§7.3).
- [x] **Count-in and metronome as scheduled events**, not a special case (§7.3).
- [x] **Offline render** to WAV, hand-written, deterministic to the byte.
- [x] FFI surface extended exactly as §3 lists it: `load_soundbank`, `load_sequence`, `set_channel_mix`, `render_offline`.

The app (`app/`):

- [x] A Standard MIDI File **reader and writer** in Dart (§5.2 item 4, §5.3), including running status, note-on-with-zero-velocity, system exclusive, and refusing format 2 rather than mangling it. 19 tests.
- [x] Soundbank scanning over the library's `soundbanks/` folder and the system's, and a playback panel on the audio screen that loads a bank and a MIDI file and plays them.

Two bugs the tests caught:

- Channel volume, pan and pitch bend were computed and never applied — the mixer existed and did nothing. Caught by asserting that a muted channel is silent.
- A zero-sustain envelope decayed forever: an exponential approaches its target without reaching it, and the floor that ends it was missing.

### M2 — what was built

Acceptance (§10 M2) — all three criteria pass:

- [x] **Create, save, load and reorder 100 songs** — `test/io/song_library_test.dart`. The scan reads headline facts only (no chart parsing), so the list is cheap; every one of the hundred then loads in full and compares equal.
- [x] **Undo/redo 50 operations without divergence** — `test/domain/command/undo_stack_test.dart`, undone and redone twice through.
- [x] **A playlist override does not mutate the song** — `test/domain/song/playlist_test.dart`, with tempo, transposition and chorus count applied at once.

Domain (`app/lib/domain/song/`, `app/lib/domain/command/`):

- [x] `ChordLeadSheet` with sealed `LeadSheetItem`s: chords, sections, repeat barlines, numbered endings, navigation marks, annotations. Immutable; every edit returns a new sheet, which is what makes undo exact.
- [x] **Form navigation (§4.5)** — `docs/rules/form-navigation.md` written first, then `navigation.dart`. Repeats, multi-bar numbered endings grouped by pass, D.C./D.S. with *al Fine* and *al Coda*, and the flattened→written bar map §4.5 insists on. Contradictory charts are *reported*, never thrown or hung on: a bar cap, a missing Segno, a Coda nothing jumps to. 29 tests.
- [x] `SongStructure`, `SongPart`, `Rhythm`/`RhythmVoice`/`RhythmParameterSpec`/`RhythmRegistry`, `MixerSettings`, `Song`.
- [x] `SongChordSequence` — the flattener, and the only input the generators will see (§4.3). With an arrangement each part contributes its section expanded by the repeats inside it, and **a part longer than its section loops the section**, which is how "play the bridge twice" is expressed. With no arrangement the written page plays as written.
- [x] `Command` / `UndoStack` / `SongCommands` (§4.4) — whole-value history over an immutable model, with keystroke merging so typing a chord is one undo step.
- [x] `Playlist` and `PlaylistEntry` with per-entry tempo, key, transposition and chorus overrides (§9). A key override takes the *shortest* way there, so "play it in Bb" goes down two rather than up ten.

Format and library (`app/lib/io/`):

- [x] `.song.json` and `.playlist.json` — plain JSON, versioned, defaults omitted so a diff shows what changed. Schema in `docs/format/song-schema.md`. Every field read by name; no reflection, no serialization framework.
- [x] Migration machinery from the first version, with its own tests — a file from the future is refused, a missing step names both versions.
- [x] **§5.4 data safety in full**, written up in `docs/rules/library-data-safety.md`: atomic write-then-rename, rolling per-song backups with pruning, a crash journal with recovery, validation on load that falls back to backups and *says so*, whole-library zip export and import, and a read-only mode for the stage. 24 tests.

UI (`app/lib/state/`, `app/lib/ui/`):

- [x] Riverpod state: library scan, view (search/sort/tag), `LibraryController`, and a `SongEditor` that runs commands through an `UndoStack`.
- [x] Library screen, Sets screen with drag-reorder and an overrides dialog, a song details screen with working undo/redo, and an app shell with a rail or bottom bar.
- [x] `SongEditor` journals the song being edited every five seconds and stops when it closes, so a crash costs seconds (§5.4).
- [x] A recovery banner on the library screen offers unsaved edits back at startup, with Restore and Discard.
- [x] **Verified on the real app.** `integration_test/library_test.dart` — 8 tests on the Linux desktop: the app opens, a song is created and edited and saved, undo and redo put the title back, the form panel reports what will play, an unsaved edit is offered back and restored, a set is made and a song added to it, and a set override leaves the stored song byte-identical.

#### How the UI is tested, and why it is split three ways

Worth writing down, because it cost an evening to find out. `testWidgets` runs
in a fake-async zone, and a future backed by real file I/O **never completes**
inside it — an empty library resolves, because nothing is read; a library with
one song in it hangs forever. `tester.runAsync` fixes I/O in the *test body* but
not I/O the widget tree starts for itself.

So the coverage is split, and each part is a real test of a real thing:

| Layer | Where | What it proves |
| --- | --- | --- |
| The screen's own decisions | `test/ui/` | Rendering, sorting, search, tag filters, the failure and recovery banners, the confirm-before-delete dialog. The scan is injected, so no disk is involved. |
| The controller and the editor | `test/state/` | Create, duplicate, delete, save, load, archive, undo/redo, the journal. Plain `test` with a `ProviderContainer` over a temp folder — no widgets, so no fake zone. |
| The two meeting | `integration_test/` | The real app on a real event loop, which is the only place both halves can run at once. |

### M1 — what was built

Domain layer at `app/lib/domain/harmony/`, framework-free and enforced as such.

- [x] `docs/rules/pitch-and-spelling.md` and `docs/rules/chord-symbols.md` — written before the code, per §15.
- [x] `Natural`, `PitchSpelling`, `Degree` — letters modular in seven, pitches modular in twelve, kept apart so spelling works. `#9` and `b3` are different degrees.
- [x] `KeySignature` — circle of fifths, diatonic spellings, and a spelling for all twelve pitch classes. Refuses keys past seven accidentals.
- [x] `SpellingPreference` — `automatic` (flat-side, as the jazz repertoire is), `sharps`, `flats`, and `key(...)`, which is what the app uses whenever the destination key is known.
- [x] `ChordType`, `ChordFamily`, `ChordTypeDatabase` — 42 core types with 148 aliases and 19 modifiers, as **data** in `app/assets/chord_types.json` (§4.1). Schema in `docs/format/chord-types.md`.
- [x] A **grammar**, not stacked regexes (§4.1): root → longest-matching core alias → modifiers → optional slash bass, with parentheses, spaces and commas treated as noise. `C13b9#11` needs no table entry; it is composed.
- [x] `ChordSymbol` with `transposed`, `respelled` and `format`. `Eb7` up a semitone is `E7`, not `Fb7`.
- [x] `ExtChordSymbol` and `ChordRenderingInfo` — accent, hold/shot, anticipation, pedal bass, `N.C.`, scale instruction (§4.1).
- [x] `StandardScale`, `StandardScaleInstance`, `ScaleLibrary` — 21 scales as data in `app/assets/scales.json`, with structural `fits()` and a `preferredFor` hint.
- [x] `Note`, `TimeSignature`, `Position` (§4.2). `TimeSignature` is general from day one; 6/8 is three quarter notes to the bar, not six.
- [x] `InstrumentTransposition` — C/Bb/Eb/F/G, applied at render time only, never mutating the stored song (§9). The written key is chosen as the *simplest* spelling of its pitch class, so an alto reading concert Db gets Bb rather than A#.
- [x] `Harmony` registry + `lib/io/harmony_assets.dart` — the only code that knows the tables are Flutter assets; the domain takes contents, never paths (ADR 0006).
- [x] `test/domain/domain_purity_test.dart` — the §15 "enforce with a lint" rule, as a test that reads the source and names the offending file and line.

Two bugs the tests caught and the design would otherwise have shipped:

- An altered dominant carries **both** `b9` and `#9`. Keying a degree set by written number silently dropped one. The set is now a list, and a `set` modifier displaces by degree index *or* semitone count.
- `C#b#b#` parsed as `C#`. Accidental runs must be homogeneous; `Cb5` is a C flat power chord and `C#b5` is a C sharp with a flattened fifth, and the parser now tells them apart.

Not built, deliberately: §9 lists "transpose to any key" and "global Bb/Eb/F/G" as M1. The **engine** for both is done and tested; the *screens* wait for a chart to transpose, which is M3.

### M0.5 — what was built

- [x] `docs/rules/corpus-tiling.md` — the mechanism written down before any code: what a source phrase is, root profiles, matching, the three scoring terms, the constraints, and the tiler.
- [x] `tools/tiling_probe/` — a deliberately self-contained Dart tool. Minimal chord model, 20 hand-entered walking bass phrases across 5 root profiles, scorer, tiler, and a Standard MIDI File writer. 55 tests, including a read-back parser that proves the MIDI is well formed.
- [x] `renders/tiling-probe.mid` (plus `-humanised` and `-with-click` variants) — 3 choruses of a 32-bar AABA form, 2:55 at 132 bpm.
- [x] Two real defects found and fixed by running it, written up in `docs/rules/corpus-tiling.md` §8.
- [x] **Listening test done (2026-09-01).** Verdict: *"corpus is too small to judge properly, scorer is too crude"* — which is the expected answer at 20 phrases and a four-line scorer, and matches findings 1, 3 and 4 in `docs/rules/corpus-tiling.md` §8. The human's instruction is to proceed and evaluate the app as a whole later. **Recorded as a debt against M6, not a passed test:** the tiling *mechanism* is accepted; whether it produces a musical line is re-tested at M6 against a real corpus and a real scorer.

### M6 debts carried forward from M0.5

- Corpus size and shape. Twenty phrases across five root profiles is enough to exercise the tiler and far too few to judge the output. §6.4 asks for 50 bass phrases and 20 drum patterns as the starting point, and the corpus must be shaped to the *segmentations* the tiler asks for, not just to common progressions (§8 finding 3).
- Scorer depth. The probe scores one note either side of a join. §6.3 calls for pre-target and post-target scoring across several notes, tempo sensitivity, and cached partial scores.
- Register handling. A phrase whose only in-range octave forces a bad seam is currently accepted; it should be rejected (§8 finding 4).

### M0 — what was built

- [x] Repo laid out per §12: `app/`, `rust/`, `docs/{rules,decisions,format}`, `tools/`, `assets/`, `benchmarks/`, root `.gitignore`, `Justfile`.
- [x] Rust workspace moved from `app/rust/` to the repo root and split into `bandstand-audio-host`, `bandstand-synth`, `bandstand-transport` plus the FFI root package (ADR 0002). All five platform build files repointed.
- [x] `bandstand-transport`: tempo map with tick↔seconds conversion across tempo changes; playhead advance with in-block loop wrapping; seqlock position publication; lock-free tempo-map handoff. 32 unit tests.
- [x] `bandstand-synth`: linear parameter ramps and the reference test tone. 13 unit tests.
- [x] `bandstand-audio-host`: cpal device enumeration, configuration scoring, output stream over seven sample formats, health counters.
- [x] FFI surface (§3): devices, start/stop, status, test tone, `transport_play/pause/stop/seek`, `set_loop`, `set_tempo`, and a synchronous `transport_position()` that reads the shared cell.
- [x] Flutter shell: dark stage theme, audio-engine screen, `Ticker`-driven playhead readout that extrapolates from `(tick, host_time)`.
- [x] `docs/rules/transport-clock.md`, `docs/rules/audio-output-path.md`; ADRs 0001–0004.
- [x] Android build verified end to end: `flutter build apk --debug` cross-compiles the Rust audio core for `armv7`, `aarch64`, `x86_64` and `i686` and produces an APK. Required raising `minSdk` to 26 — see ADR 0005, AAudio does not exist below it.
- [x] **Android leg of the M0 acceptance test — done at M8 (2026-09-04), on an API 37 emulator.** It could not have passed before: cpal's Android backend reaches the platform through JNI and asks `ndk_context` for a `JavaVM` and a `Context`, and nothing in a Flutter app's load path supplies them, so the first call that opened a device died with `PanicException(android context was not initialized)`. Fixed by ADR 0009. The engine now opens a device on Android, renders blocks, advances the playhead, and plays a minute of a General MIDI sequence with the dropout counter at zero. **Whether the tone is *heard* is still a human's judgement** — the same class as the M4 listening test — but everything a machine can check is checked, by `integration_test/platform_audio_test.dart` and the four suites `just android-test` runs.

---

## 1. Legal ground rules (read before writing code)

**JJazzLab's licence is internally ambiguous — resolve this before publishing, not after.** Verified on the current tree:

| Source | States |
| --- | --- |
| `LICENSE` file | LGPL **2.1** |
| `pom.xml` `<licenses>` | LGPL **2.1** |
| GitHub repo description | LGPL v2.1 |
| **993 of ~997 Java file headers** | **LGPLv3** — "version 3 of the License, or (at your option) any later version" |
| 4 stray Java headers | version 2.1 |

The difference is not cosmetic: LGPLv3 incorporates GPLv3 terms (patent grant, Installation Information for User Products, and materially worse friction for app-store distribution) and its relinking clause differs from 2.1's. Per-file headers normally govern, but a direct conflict with the LICENSE file is genuinely unsettled.

**Action, and it is cheap:** email Jerome Lelasseux and ask which he intends. Do it now, while you are only reading the code, rather than in eighteen months when you want to ship. Record the answer in `docs/decisions/`.

FluidSynth is LGPL-2.1. abc2svg is LGPL-3.0. Wim Vree's converters are LGPL.

- **Personal use triggers nothing.** LGPL obligations attach to *distribution*. If this stays on your own machines, none of this matters.
- **If you ever publish**, a line-by-line translation of LGPL Java into Dart or Rust is a derivative work. Changing language does not launder the licence.
- **The safe discipline**, which costs almost nothing and preserves your options: work from *documented formats and written-down rules*, not from a source file open in the adjacent window. Read JJazzLab to understand an algorithm, write the algorithm down in `docs/rules/<topic>.md` in prose, then implement from your prose. Keep the prose notes in the repo as evidence of process.
- **Use JJazzLab as a behavioural oracle freely** (§11). Comparing outputs is not copying.
- **Do not vendor the JJazzLab SoundFont or the jjSwing MIDI phrase databases into your repo** if you intend to publish. Build your own corpus (§6.4).
- **Sample provenance is a bigger exposure than any code licence here.** SoundFont lineage in the wild is murky and frequently untraceable. For personal use, use whatever sounds good. Before publishing, either license a bank with clean paperwork, commission recordings, or build on explicitly-licensed sources (e.g. CC0/CC-BY instrument libraries) — and record the provenance of every sample set in `docs/decisions/`.
- Get one hour of a lawyer's time before publishing anything. Not before starting.

---

## 2. Feasibility verification (measured, not estimated)

Measured against a fresh clone of `github.com/jjazzboss/JJazzLab` (5.x):

| Area | Files | Code lines |
| --- | --- | --- |
| Whole repo | 1,177 | ~190,000 |
| `app/` (NetBeans GUI) | 585 | 81,000 |
| `core/` | 284 | 52,000 |
| `model/` | 219 | 41,500 |
| `plugins/` | 89 | 15,300 |
| Files importing Swing/AWT/NetBeans windowing | 594 | 102,000 |
| Files with no UI imports | 583 | 88,000 |

Of the 88k non-UI lines, large chunks are irrelevant to this project:

- `core/EmbeddedSynth` — 21,000 lines, of which **98% is a bundled pure-Java LAME MP3 encoder** (29,732 of the module's 30,235 raw lines sit under `lame/`; `lame/mp3/PsyModel.java` alone is 2,900). Replaced by a Rust encoder or dropped.
- `model/Midi` — 15,000 lines, largely MIDI device handling, synth definitions, GM/GM2/XG instrument banks. Replaced by the Rust audio core.

**The part you actually reimplement is ~30,000 lines**, and only ~15,000 of that is conceptually hard:

| Module | Code lines | Role |
| --- | --- | --- |
| `model/Harmony` | 4,214 | Notes, chord symbols, chord types, degrees, scales, time signatures |
| `model/Phrase` | 2,972 | NoteEvent, Phrase, SizedPhrase, Grid |
| `model/Song` | 4,191 | ChordLeadSheet, SongStructure, SongPart, Section |
| `core/RhythmMusicGeneration` | 3,628 | ChordSequence, SongSequenceBuilder, accents, anticipation |
| `plugins/JJSwing` | 7,497 | Corpus-tiling walking bass + drums |
| `plugins/YamJJazz` | 6,015 | Yamaha SFF1/SFF2 + CASM style engine |

### Verdict: tractable, not straightforward

Be clear-eyed. Four things are genuinely hard, and they are not evenly distributed:

1. **Comping and bass quality** — unbounded musical R&D. There is no "done". This is the whole product.
2. **The SF2/SFZ sampler** — correctness (loop points, modulators, filters, round-robin) plus a mobile memory budget that forbids resident samples.
3. **Chart layout** — repeats, endings, codas, segnos, pickup bars, multi-bar rests, and reflow across screen sizes. Deceptively fiddly; every edge case is visible on stage.
4. **YamJJazz / CASM**, *if* you want the 300-style library. Documented binary format, so it is a grind rather than research — but a 3–6 month grind.

Everything else — the domain model, the file formats, the importers, the transport, the playlist layer, the UI shell — is mechanical work that an agent can do quickly and correctly with tests.

**Realistic shape:** ~4–6 months of evenings to a tool you use daily (M0–M5). 12–18 months to something comprehensive. Generators are never finished.

### Non-goals

Write these down now; they are what keeps the project finishable.

- **Not a DAW:** no multitrack audio recording, no waveform editing, no plugin hosting.
- **Not a notation editor:** no engraving, no part layout, no beaming decisions. Charts, not scores.
- **No cloud**, no accounts, no sync service, no sharing, no collaboration.
- **No web build.**
- **No audio-input score following, no automatic transcription, no photo-to-chart OMR** in v1. Revisit only after M9.
- **No attempt to match Band-in-a-Box's recorded-audio backing.** This is a MIDI-and-samples instrument, and its quality ceiling is set by the corpus and the sampler.

---

## 3. Architecture

```plaintext
┌──────────────────────────────────────────────────────┐
│ Flutter / Dart                                       │
│  ├── ui/          screens, reading mode, editor      │
│  ├── render/      CustomPainter chart engine         │
│  ├── domain/      harmony, phrase, song, generation  │
│  └── io/          importers, exporters, library      │
└───────────────┬──────────────────────────────────────┘
                │ flutter_rust_bridge (FFI)
┌───────────────┴──────────────────────────────────────┐
│ Rust                                                 │
│  ├── audio-host/  cpal / oboe / CoreAudio backends   │
│  ├── synth/       SF2/SFZ sampler, voices, effects   │
│  ├── sequencer/   sample-accurate event scheduler    │
│  ├── transport/   clock, tempo map, loop, position   │
│  └── ffi/         bridge surface, shared atomics     │
└──────────────────────────────────────────────────────┘
```

### Boundary rules

- **Dart owns:** the song model, chord parsing, all music generation, chart layout, all UI, file I/O for songs.
- **Rust owns:** everything after "here is a list of scheduled MIDI events" — sampling, mixing, device I/O, and the transport clock.
- **The FFI surface is deliberately tiny:**
  - `load_soundbank(path) -> BankHandle`
  - `set_program(channel, bank, program)`
  - `load_sequence(events: Vec<TimedEvent>, ppq, tempo_map)`
  - `transport_play() / pause() / stop() / seek(tick)`
  - `set_loop(start_tick, end_tick, enabled)`
  - `set_channel_mix(channel, volume, pan, mute)`
  - `set_tempo(bpm)`
  - `render_offline(out_path, format)` — for bouncing
  - **Position readback via a shared atomic**, not a callback. Rust writes `(tick, host_time_ns)` atomically each audio block; Dart reads it in a `Ticker` and interpolates. Never poll over FFI per frame.
- **Generation is not real-time.** Dart builds the whole sequence, hands it over, Rust plays it. Regeneration on a chord edit rebuilds and reloads — target under 200 ms end to end.

### Why this split

Symbolic music generation is allocation-heavy, constantly rewritten, and needs stateful hot reload — Dart. Audio is a real-time thread where a GC pause is an audible glitch — Rust. `flutter_rust_bridge` gives a direct FFI boundary, so cursor sync is a shared atomic rather than IPC.

### Performance budgets

Design against these; assert them in benchmarks (§11.3).

| Metric | Target | Hard limit |
| --- | --- | --- |
| Audio output latency, desktop | 10 ms | 25 ms |
| Audio output latency, Android | 25 ms | 60 ms |
| Dropouts during a 90-minute set | 0 | 0 |
| Full regeneration after a chord edit | 100 ms | 300 ms |
| Chart repaint, cursor frame | 4 ms | 8 ms |
| Cursor drift over 5 minutes | 10 ms | 20 ms |
| Cold start to library visible | 1 s | 3 s |
| Resident memory, desktop | 400 MB | 1 GB |
| Resident memory, Android tablet | 250 MB | 500 MB |

The memory line is what forces sample streaming (§7.2). Settle it before the sampler exists.

---

## 4. Domain model specification

This is the layer to get right. Everything else depends on it. Reference for concepts: `model/Harmony`, `model/Phrase`, `model/Song`.

### 4.1 Pitch and harmony

```dart
/// Absolute pitch, MIDI 0-127.
class Note {
  final int pitch;          // 60 = C4
  final double beatDuration;
  final int velocity;
}

/// Interval from a root, spelled. NOT a pitch class — spelling matters
/// for display (#9 vs b3) and for scale/voicing decisions.
enum Natural { c, d, e, f, g, a, b }
class Degree {
  final Natural natural;    // scale degree letter
  final int alteration;     // -1 flat, 0, +1 sharp
  int get semitones;
}

/// Chord quality, defined as an ordered set of degrees.
class ChordType {
  final List<Degree> degrees;
  final String name;        // "7", "m7b5", "13#11", "maj7#5"
  final ChordFamily family; // major, minor, dominant, diminished, augmented, sus, other
  bool get isMinorish;
  Degree? degreeFor(int semitones);
}

/// Root + type (+ optional bass for slash chords).
class ChordSymbol {
  final Natural rootNatural; final int rootAlteration;
  final ChordType type;
  final ChordSymbol? bass;  // slash chord
  ChordSymbol transposed(int semitones, {SpellingPreference? pref});
}

/// Chord symbol plus rendering hints: accent, hold, shot, anticipation,
/// scale instruction, "no chord", pedal bass.
class ExtChordSymbol extends ChordSymbol {
  final ChordRenderingInfo rendering;
  final StandardScaleInstance? scale;
}
```

**Requirements:**

- A **chord-type database** keyed by every alias you will encounter: `Δ ^ maj M`, `- m min`, `ø h m7b5`, `o dim`, `+ aug`, `sus sus4 sus2`, `alt`, `add9`, `6/9`, `13b9#11`. Build it as data (a table in `assets/chord_types.json`), not code. Parse with a grammar, not regexes stacked on regexes.
- **Enharmonic spelling is a first-class concern.** Transposing Eb7 up a semitone gives E7, not Fb7; up a tritone gives A7. Implement a spelling preference driven by the destination key signature. Test this hard — it is the single most visible correctness bug in a transposing chart reader.
- **Scales** (`StandardScale`) matter later, for voicing and improvisation hints. Model them now: name + degree list + which chord types they fit.

### 4.2 Time and phrases

```dart
class TimeSignature { final int upper, lower; }
class Position { final int bar; final double beat; }

class NoteEvent extends Note {
  final double positionInBeats;
  final Map<String, Object> clientProperties;  // tagging during generation
}

/// Ordered collection of NoteEvents on one channel.
class Phrase {
  final int channel;
  final bool isDrums;
  void add(NoteEvent e);
  Phrase transposed(int semitones);
  Phrase shifted(double beats);
  Phrase getProcessed(bool Function(NoteEvent) filter, NoteEvent Function(NoteEvent) map);
  Phrase sliced(FloatRange range, {bool cutNotes});
}

/// Phrase with a fixed size and start position — the unit of generation.
class SizedPhrase extends Phrase {
  final FloatRange beatRange;
  final TimeSignature timeSignature;
}
```

### 4.3 Song structure

Two distinct layers. Keep them separate — this is one of JJazzLab's best design decisions.

```dart
/// The written chart: bars, chord symbols, section markers. Linear.
class ChordLeadSheet {
  int get barCount;
  List<ChordLeadSheetItem> get items;   // chord symbols, sections, annotations
  Section? sectionAt(int bar);
  void insertBars(int at, int count);
  // emits change events; drives undo/redo
}

/// The arrangement: which sections play, in what order, how many times,
/// with which rhythm and which parameter values.
class SongStructure {
  List<SongPart> get songParts;
}

class SongPart {
  final Section parentSection;   // points into the ChordLeadSheet
  final int startBar, barCount;
  final Rhythm rhythm;
  final Map<RhythmParameter, Object> rpValues;  // intensity, variation, fill, ...
}

class Song {
  final String title, composer;
  final ChordLeadSheet leadSheet;
  final SongStructure structure;
  final int tempo;
  final MixerSettings mixer;
  final Map<String, String> meta;   // key, style hint, tags, comments
}
```

**Flattening** — `ChordLeadSheet` + `SongStructure` → `SongChordSequence`, a linear bar-by-bar list of chord symbols with absolute positions. This is the *only* input the generators see. Reference concept: `core/RhythmMusicGeneration/ChordSequence`, `SongChordSequence`.

### 4.4 Undo/redo

Command pattern over the two model classes from day one. Retrofitting undo into a chart editor is miserable. Every mutation is a command with `do`/`undo`; the UI never mutates the model directly.

### 4.5 Form navigation — do not skip this

Charts are not linear. The `ChordLeadSheet` stores the written page, including repeat barlines, numbered endings, D.C., D.S., segno, coda and fine. Flattening to `SongChordSequence` must **resolve** those into a linear bar sequence, and this is the single most common source of "the backing track went to the wrong bar" bugs.

Requirements:

- Model repeat start/end with a repeat count, numbered endings, and navigation marks as first-class items in the lead sheet.
- Resolve them in a defined, tested order during flattening.
- **Retain a map from flattened bar index → source bar index**, so the cursor can highlight the correct place on the written page while playback runs through the expansion. Without this map, the cursor is wrong on any tune with repeats — which is most tunes.
- Reject or flag unresolvable structures at import rather than at playback.

Reference: `core/Importers/src/main/java/org/jjazz/importers/musicxml/` — `BarNavigationIterator.java`, `NavigationMark.java`, `CLI_Repeat.java`, `CLI_Ending.java`.

### 4.6 Meter scope

Ship 4/4 first. 3/4, 6/8, 5/4 and 7/4 are less a code problem than a corpus problem: every generator corpus is per-meter (JJazzLab's drum corpus is `drums44DB.mid` — 4/4 only). Model `TimeSignature` generally from day one, support mid-song changes in the model, but do not offer meters you have no phrases for.

---

## 5. File formats and import

### 5.1 Native format

Plain JSON, versioned, human-diffable, one file per song, `.song.json`. No binary, no serialization framework, no reflection. Schema in `docs/format/song-schema.md`, with `schemaVersion` and a migration function per version bump.

Library layout on disk:

```plaintext
~/Music/Bandstand/
  songs/<uuid>.song.json
  playlists/<uuid>.playlist.json
  corpora/                     # your phrase corpora (§6.4)
  soundbanks/
  renders/                     # bounced audio
```

Flat files in a user-visible folder. Sync between your own machines is then Syncthing or a USB stick — no code, no cloud.

### 5.2 Importers (priority order)

1. **iReal Pro `irealbook://` and `irealb://`** — the highest-leverage feature in this entire plan. Thousands of existing charts, and it is how you populate your library in an evening rather than a year. The `irealbook://` variant is plain text; the `irealb://` variant is obfuscated but the scheme is publicly documented in several open implementations (`pyRealParser`, `ireal-reader`, `Data-iRealPro`, the `ireal_parser` Rust crate). Official format notes: `irealpro.com/ireal-pro-file-format/`.
   - Parse: title, composer, style, key, tempo, repeats, and the chord string with its bar lines (`|`), section markers (`*A *B *C`), repeats (`{ }`), endings (`N1 N2`), codas/segnos, `x` (repeat bar), `s`/`l` (small/large chord), `U` (end), `Z` (double bar), `T44` time signatures, `N.C.`, alternate chords in parens.
   - **Acceptance test:** round-trip 200 charts, assert bar counts and chord sequences match a reference parser's output.
2. **MusicXML** — chords via `<harmony>`, plus melody if present, plus the repeat/ending/navigation structure (§4.5). Also your export path. Test against the **Unofficial MusicXML Test Suite** (~130 files, originally built for LilyPond's importer) — it is data, not code, so no licence question, and it is a ready-made acceptance corpus.
3. **Plain text lead sheet** — `| C6 | Am7 | Dm7 G7 |`. Trivial, and the fastest way for *you* to enter a tune.
4. **MIDI import** — for bringing in your own phrase corpus (§6.4), not for songs.
5. *(Optional, later)* JJazzLab `.sng` — XStream XML, readable but ugly. Only worth it if you have existing arrangements to rescue.

### 5.3 Exporters

MIDI (multi-track, with markers per song part), WAV/FLAC via offline render, PDF chart (via Flutter's `printing`/`pdf` packages, reusing the same `CustomPainter` layout), MusicXML.

### 5.4 Data safety

A corrupted library the night before a gig is the worst failure this app can have. All of this is cheap and belongs in M2:

- **Atomic writes:** write `<file>.tmp`, `fsync`, rename. Never write in place.
- **Rolling backups:** keep the last N versions of each song under `.backups/`, pruned by age.
- **Journal in-progress edits** so a crash costs seconds, not a session.
- **Validate on load.** On schema failure, fall back to the last good backup and say so — never silently show an empty library.
- **Whole-library export as a single zip**, one menu item. This is both disaster recovery and how you move to a new machine.
- **Reading mode is strictly read-only.** The app cannot write to a song file while in performance mode. No accidental edits on stage.

---

## 6. The generation engine

### 6.1 Pipeline

```plaintext
Song
 └─ flatten → SongChordSequence (bar, position, ExtChordSymbol)
     └─ for each SongPart:
         └─ for each RhythmVoice (bass, drums, piano, guitar, ...):
             └─ Generator.generate(context) → SizedPhrase
                 └─ post-processing chain:
                     accents · anticipation · humanize · velocity shaping
                     · voice-range clamp · overlap fix
             └─ assemble → Map<RhythmVoice, Phrase>
                 └─ → TimedEvent list → Rust
```

Reference concepts: `core/RhythmMusicGeneration/SongSequenceBuilder`, `AccentProcessor`, `AnticipatedChordProcessor`, `core/Humanizer`, `core/PhraseTransform`, `core/Quantizer`.

### 6.2 Generator interface

```dart
abstract class MusicGenerator {
  String get id;
  List<RhythmVoice> get voices;
  List<RhythmParameter> get parameters;
  Map<RhythmVoice, SizedPhrase> generate(GenerationContext ctx);
}

class GenerationContext {
  final SimpleChordSequence chords;   // this song part only
  final FloatRange beatRange;
  final TimeSignature timeSignature;
  final int tempo;
  final Map<RhythmParameter, Object> parameterValues;
  final int randomSeed;               // MUST be explicit — see §11
}
```

**Seed the RNG explicitly and thread it through.** Determinism is what makes the whole test strategy possible, and it also gives the user a "reroll" button that is reproducible.

### 6.3 The key architectural finding: corpus tiling

Inspection of `plugins/JJSwing` shows the newest and best-regarded engine in JJazzLab is **not rule-based**. It is a **corpus of transcribed MIDI phrases, sliced, scored and tiled** over the chord progression:

- The entire corpus is **~96 KB in four MIDI files**: `bass/db/WalkingBassMidiDB.mid` (51.6 KB), `WalkingBass2feelBMidiDB.mid` (17.6 KB), `WalkingBass2feelAMidiDB.mid` (14.5 KB), `drums/db/drums44DB.mid` (11.9 KB). Note the drum corpus is 4/4 only — meter coverage is a corpus decision, not a code decision (§4.6).
- `WbpSource` = a 1–4 bar source phrase, tagged with the chord sequence it was played over, plus derived stats: starts on root?, ends on chord tone?, first/last note, a `RootProfile`, and a per-destination-root **transposibility** map.
- `WbpTiling` / `Tiler*` / `WbpsaScorer` = choose a covering of the progression from scored candidate phrases. Verified mechanism: the scorer computes **pre-target and post-target note-matching scores at every join** — i.e. voice leading between the last note of one phrase and the first note of the next — plus constraints rejecting non-root start notes and non-chord-tone final notes, with tempo taken into account and partial scores cached across tiling attempts. Two greedy tilers ship: longest-phrase-first-without-repetition, and maximum-distance-between-reuses. A tiling that fails its constraints scores zero and is discarded.
- The scoring function is where the musical judgement lives. It is small, pure, and tunable by ear — which is exactly the property you want.

**This is the architecture to adopt.** It is why jjSwing sounds better than the loop-based style engine, and it has three properties you want:

1. Quality scales with corpus size and quality, not with code complexity.
2. **You can build the corpus yourself** by playing bass lines and comping into a DAW over known progressions — which makes it *yours*, cleanly, with no licence question.
3. The hard part is a scoring function, which is exactly the kind of thing you can tune by ear in a hot-reload loop.

### 6.4 Building your own corpus

This is a musical task, not a coding task, and it is the highest-value work in the project.

- Record or program 2–4 bar phrases over common progressions: ii-V-I major and minor, I-VI-ii-V, blues turnarounds, rhythm changes A and B, modal vamps, static dominant, descending chromatic.
- Per phrase, store: MIDI notes, the chord sequence it was played over, style tags (`walking`, `two-feel`, `pedal`, `broken`, `latin`), tempo range, and intensity.
- Ingest tool: `tools/corpus_import.dart` — takes a MIDI file plus a chord annotation file, slices at bar boundaries, computes stats, writes `corpora/<name>/*.json`.
- Start with 50 bass phrases and 20 drum patterns. That is enough to hear whether the tiling and scoring work.

### 6.5 Generators to build, in order

1. **Drums** — pattern-based with fills and variation slots. Easiest, and it is what makes everything else feel like music.
2. **Walking bass** — corpus tiling per §6.3. The centrepiece.
3. **Piano/guitar comping** — rhythmic pattern corpus × voicing engine. Split these two concerns: *when* to play (corpus of rhythmic cells) and *what notes* (voicing engine below).
4. **Voicing engine** — rootless A/B voicings, drop-2, quartal, shells; guide-tone-driven voice leading between successive chords with minimal movement; register constraints. Pure, deterministic, and extremely testable.
5. *(Optional, much later)* **YamJJazz/SFF** for style breadth. Only if you want the 300-style library. Format: SFF1/SFF2 with CASM sections controlling per-channel note transposition rules (NTR) and tables (NTT). Reference: `plugins/YamJJazz/CASMDataReader.java`, `rhythm/api/YamJJazzRhythmGenerator.java`, `CtabChannelSettings.java`.

### 6.6 Arrangement-level features (what stops it sounding like a loop)

The known ceiling of loop-based backing is audible repetition over a 32-bar form. Design against this from the start:

- **Density arc** across choruses — head quieter, solos build, last chorus back down.
- **Variation selection** driven by song position, not by a random draw per bar.
- **Fills** at section boundaries and every 4/8 bars, chosen by intensity.
- **Intro / ending** generation.
- **Anticipation** — push chords an eighth before the bar when the source phrase supports it.
- **Humanization** — timing and velocity jitter with correlated, not independent, noise.

---

## 7. Rust audio core

### 7.1 Crates

```plaintext
rust/                          # cargo workspace
  bandstand-audio-host/        device enumeration + stream setup (cpal; oboe on Android)
  bandstand-synth/             SF2/SFZ parsing, voice allocation, DSP
  bandstand-sequencer/         event scheduling, tempo map, loop, count-in, metronome
  bandstand-transport/         clock, shared position atomics
  bandstand-ffi/               flutter_rust_bridge surface
```

### 7.2 Synth requirements

- **SF2 first** (you already have banks), SFZ later (better articulation control, plain text, easier to author).
- Voice pipeline: sample playback with cubic interpolation → volume + modulation envelopes → low-pass filter with resonance → LFOs → pan → send to reverb/chorus bus.
- Loop points, key/velocity zones, round-robin, exclusive classes (hi-hat open/closed), release samples.
- **Polyphony cap with a sensible voice-stealing policy** (oldest released, then quietest).
- Effects: a decent reverb (Freeverb-class is fine), chorus, per-channel EQ. Nothing fancy.
- **Mobile memory:** a full bank cannot be resident. Implement `mmap`-backed sample access with an LRU page cache, or a preprocessed streaming format. Decide this before writing the sampler — retrofitting is a rewrite.

### 7.3 Transport

- Sample-accurate scheduling. All events resolved to sample offsets within the current audio block.
- Tempo map supporting mid-song changes.
- Loop points with correct note-off handling at the wrap.
- Count-in and metronome as scheduled events, not a special case.
- **Position readback:** on each block, write `(tick, host_time)` to an `AtomicU64` pair. Dart reads and interpolates in a `Ticker`. Cursor jitter is then a rendering concern, not an IPC concern.

### 7.4 Platform backends

| Platform | Backend | Notes |
| --- | --- | --- |
| Linux | cpal → ALSA/PipeWire | Dev machine. Watch for PipeWire buffer negotiation. |
| Windows | cpal → WASAPI | Offer exclusive mode for low latency. |
| macOS | cpal → CoreAudio | Straightforward. |
| Android | Oboe (AAudio, OpenSL fallback) | Needs audio focus handling + a **foreground service**, or playback dies on screen lock. |
| iOS | CoreAudio | Needs `AVAudioSession` category `.playback` configured, or the silent switch kills you on stage. |

Android and iOS session handling are Flutter plugin work in Kotlin/Swift. Budget 2–3 weeks each, mostly reading platform docs.

### 7.5 MIDI I/O

`midir` covers ALSA, WinMM, CoreMIDI (macOS and iOS). **Android needs a JNI shim** over `android.media.midi`. Needed for: BLE/USB foot pedal page turns, and later live chord input.

---

## 8. Flutter UI

### 8.1 Chart renderer

A single `CustomPainter`. No engraving library, no webview, no SVG. You are drawing: bar grid, chord symbols, section letters, repeat structures, endings, coda/segno marks, bar numbers, a cursor, and optional lyrics or notes.

Layout algorithm:

1. Flatten the lead sheet into a list of bars with their chord symbols and structural marks.
2. Break into lines using a target bars-per-line (4 typical, 2 for dense charts, 8 for simple), respecting section boundaries — **a section never starts mid-line**.
3. Reflow on resize/orientation with a measured minimum bar width; below that, reduce bars-per-line rather than shrinking type.
4. Paint. Cache a `Picture` per line, repaint only the cursor layer per frame.

**Non-negotiable for stage use:** legible at 2 metres. Test by putting the tablet on a stand and stepping back, not by looking at it on your desk.

Reading-mode requirements: no chrome, huge chord type, high-contrast dark theme, tap-zones only at the far left/right edges, wake lock on, orientation lock, no gesture that can destroy the chart by accident.

### 8.2 Screens

| Screen | Purpose |
| --- | --- |
| Library | Search, filter by style/key/tag, sort. Fast. This is the screen you use most. |
| Playlist / setlist | Ordered, drag-reorder, per-song tempo and key overrides stored **on the playlist entry, not the song** (§9). |
| Reading mode | Full-screen chart, cursor, transport, minimal chrome. |
| Editor | Bar grid entry, chord palette, section markers, repeats. Keyboard-driven on desktop, tap-driven on tablet. |
| Arrangement | Song parts, rhythm choice, per-part parameters, chorus count. |
| Mixer | Per-voice volume/mute/solo/instrument. |
| Practice | Tempo ramp, key cycling, loop selection, count-in. |
| Settings | Audio device, buffer size, soundbank, MIDI devices, theme. |

### 8.3 State management

Riverpod or Bloc — pick one and be consistent. The domain model stays framework-free; providers wrap it. Domain code must be testable in `dart test` with no Flutter dependency.

---

## 9. iReal Pro feature analysis

You named iReal Pro as the reference for playlists, transposition and charts. Its current feature set, with a verdict on each:

| Feature | Verdict | Notes |
| --- | --- | --- |
| Playlists of charts for gigs/sets/lessons | **Build in M2** | The core organising concept. Cheap. |
| Per-entry tempo/key/repeat overrides | **Build in M2** | Critical detail: the *same tune* appears in two sets in different keys. Store overrides on the playlist entry. |
| Transpose to any key, instantly | **Build in M1** | Requires the spelling engine (§4.1). |
| Global Bb/Eb/F/G transposition for horn players | **Build in M1** | One setting, applied at render time only. Never mutate the stored song. |
| 50+ accompaniment styles | **Partial, M6+** | Your differentiator is depth over breadth. Three excellent styles beat fifty adequate ones. |
| Per-style instrument choice + mixer | **Build in M5** | Cheap once voices exist. |
| Loop a selection of bars | **Build in M4** | Highest-value practice feature. |
| Automatic tempo increase per repeat | **Build in M7** | Trivial once transport exists. Disproportionately useful. |
| Automatic key cycling per chorus | **Build in M7** | Same. |
| Built-in chart editor | **Build in M3** | Must be fast. Chord entry is the friction point. |
| Guitar/uke/piano chord diagrams | **Build in M8** | Pure data + a small painter. Nice, self-contained, low risk. |
| Scale suggestions for improvisation | **Build in M8** | You already need the scale model for voicings. |
| Bluetooth page turner support (AirTurn) | **Build in M8** | Just MIDI/HID input mapped to next/prev. |
| Export PDF / MusicXML / MIDI / audio | **Build in M6** | Reuse the painter for PDF. |
| Community chart library, forum sharing | **Skip; import instead** | Excluded by scope — but implement the *import* path (§5.2), which gives you the corpus without the infrastructure. |
| iCloud sync across devices | **Skip** | Flat files + Syncthing. |
| Recording yourself over the accompaniment | **Consider, M9** | Genuinely useful for practice. Needs an input path in the Rust core. |
| Number notation (Nashville) display | ✅ **done** (M8 domain, M9 on the chart) | Falls out of the degree model almost free — and it did, for the numbers. Reaching the *chart* took M9: `Nashville.format` and the chord reference screen have existed since M8, but the feature is for reading a tune in a key nobody wrote it in, and you do that on the chart, not in a lookup table. Reading mode now has a toggle. `docs/rules/chart-layout.md` §6b. |

### What iReal Pro does not do, and you should

1. **Notated melody alongside the chart.** Learning heads is half the deadline problem.
2. **Literal playback of a written part** (pit book, horn part) as well as generated backing.
3. **Corpus-based bass and comping** instead of loops — less repetition over a long form.
4. **Import breadth** — iReal Pro is a walled garden by design; you can read everything.
5. **Desktop-first editing** with a real keyboard.

---

## 10. Milestones

Each milestone: deliverable, then acceptance test. Do not proceed until the test passes.

### M0 — Skeleton (1–2 weeks) — ✅ done on both

Flutter app shell for Linux + Android. `flutter_rust_bridge` wired. Rust plays a sine wave through cpal on both.
**Accept:** sine wave on both platforms, no glitches, position atomic readable from Dart.

### M0.5 — Prove the central bet (1–2 weeks) — DO THIS BEFORE M1 — ✅ mechanism accepted; corpus and scorer quality deferred to M6

The whole plan rests on one unproven assumption: that corpus tiling produces musical bass lines rather than audibly stitched fragments. Test it in a throwaway script before building anything that depends on it.

Hand-enter 15–20 walking bass phrases of 2 bars each over known progressions (ii-V-I major and minor, I-VI-ii-V, a blues turnaround). Write a crude scorer — harmonic fit plus interval size at the join — and a greedy longest-first tiler. Render a 32-bar form to MIDI. Play it through any synth.
**Accept:** you listen to three choruses and it sounds like a bass player having an ordinary day, not like a shuffled deck. If it doesn't, find out why now — corpus too small, scorer too crude, or the paradigm doesn't hold — while the cost is a fortnight.

### M1 — Harmony core (3–4 weeks) — ✅ done

`Note`, `Degree`, `ChordType`, `ChordSymbol`, `Scale`, `TimeSignature`, `Position`. Chord-type database as data. Parser and formatter. Transposition with correct spelling. Global instrument transposition.
**Accept:** 500-case parser test suite; transpose every chord type through all 12 keys and assert spelling; property test that parse(format(x)) == x.

### M2 — Song model, library, playlists (3–4 weeks) — ✅ done

`ChordLeadSheet`, `SongStructure`, `SongPart`, `Song`. JSON format + migrations. Command-pattern undo. Library screen. Playlists with per-entry overrides.
**Accept:** create, save, load, reorder 100 songs; undo/redo 50 operations without divergence; playlist override does not mutate the song.

### M3 — Chart renderer + editor (4–6 weeks) — 🟡 layout engine done — 🟡 built; two acceptance criteria need a human

`CustomPainter` layout with repeats, endings, codas, pickup bars. Reflow. Reading mode. Editor.
**Accept:** render 50 imported iReal charts with correct bar counts and structure; readable at 2 m on the tablet; edit a 32-bar tune in under 2 minutes.

### M4 — Rust synth + transport (6–8 weeks) — ✅ done

SF2 parsing, voice allocation, envelopes, filter, reverb. Sequencer, tempo map, loop, count-in. Position atomics. Cursor synced to playback.
**Accept:** play a General MIDI file and A/B it against FluidSynth — no audible defects; cursor drift under 20 ms over 5 minutes; no dropouts at 256-frame buffer for an hour.

### M5 — First generator: drums + mixer (4 weeks) — ✅ done

Pattern-based drum generator with variations and fills. Voice/mixer model. Generation pipeline end to end.
**Accept:** press play on an imported chart and hear time; regeneration after a chord edit under 200 ms.

### M6 — Walking bass via corpus tiling (8–12 weeks) — 🟡 built and measured; the listening test is the human's

Corpus format and import tool. Record your own initial corpus. Slicing, stats, transposibility, scoring, tiling.
**Accept:** blind listening test — bass line over a ii-V-I sequence is indistinguishable from a competent human transcription to you, and does not repeat audibly over 3 choruses.

### M7 — Comping, voicings, practice features (8–12 weeks) — ✅ done

Rhythmic cell corpus + voicing engine with guide-tone voice leading. Tempo ramp, key cycling, loop practice.
**Accept:** voicings pass a music-theory test suite (no root doubling in rootless voicings, voice movement under 4 semitones between successive chords, no interval clashes); tempo ramp works over a 20-minute session.

### M8 — Mobile hardening + reference features (6–8 weeks) — 🟡 all but battery drain

Android audio focus + foreground service; iOS `AVAudioSession` if targeting iPad. Sample streaming. Chord diagrams, scale hints, page-turner input, Nashville numbers.
**Accept:** 90-minute set on the tablet, screen locked and unlocked repeatedly, no audio interruption, battery drain acceptable.

### M9 — Export, polish, optional extras (ongoing) — 🟡 exporters, importers and test infrastructure built

MIDI/audio/PDF/MusicXML export. Offline render. Optionally: melody display, literal part playback, self-recording.

Done in M9 so far: the four exporters (§5.3), the two remaining importers
(§5.2 — MusicXML and plain text), the §11.3 benchmark suite, and the §11.2 audio
null test. Outstanding: the three optional extras above, and §11.1's oracle
harness — see the assessment there, which is a toolchain decision rather than
engineering work.

#### The test infrastructure of §11, built in M9

- [x] **§11.3 benchmarks** — `benchmarks/run.sh`, `just bench "heading"`. Every
  §3 budget measured together and appended to `docs/benchmarks.md`. Four had
  never been measured: layout per 100 bars, the cursor frame, synth CPU at 64
  voices, and cold start. Measuring the layout found it was **quadratic in bar
  count** and the fix made 400 bars five times faster.
- [x] **§11.2 audio null test** — `rust/tests/audio_null_test.rs`. A fixed
  ii–V–I rendered offline and compared sample for sample against a stored
  reference, keyed to the soundfont it describes so it never passes vacuously.
  Verified by perturbation: a 0.1% master-gain change fails it.
- [ ] **§11.1 golden-master oracle** — blocked on a toolchain decision, assessed
  in full in that section. Not started, and deliberately not stubbed.

---

## 11. Test strategy

### 11.1 Golden-master harness against JJazzLab

Build this in M1 and keep it running. **Note the §1 discipline: use it as a behavioural oracle, not as a source to translate.**

```plaintext
tools/oracle/
  generate_cases.dart      # N chord progressions × styles × parameters
  run_jjazzlab.sh          # headless JJazzLab Toolkit → .mid per case
  compare.dart             # structural diff of MIDI output
```

Use it for: chord parsing, transposition, chart structure flattening, and — where you deliberately match behaviour — generation. Where you intend to *differ*, record the difference as an expected deviation with a reason.

**Status: ⛔ blocked on the toolchain, not on the work** (assessed 2026-09-05). The
harness is not built, and building it needs a decision that is the human's:

- The source tree at `/home/vladimir/develop/refs/JJazzLab/` is a **Maven
  multi-module NetBeans platform application**. There is no `mvn` on this machine
  (`java` is OpenJDK 21), no Maven wrapper in the tree, and `~/.m2/repository`
  has neither Guava nor the NetBeans `openide-util` artifacts cached.
- **There is no headless toolkit module.** The plan's `run_jjazzlab.sh` assumes a
  "headless JJazzLab Toolkit"; the tree's modules are `model/*`, `core/*` and
  `app/*`, and generation is reached through NetBeans `Lookup` service
  registration from inside the platform application. Driving it without a GUI is
  not a matter of picking a different entry point.
- Even the narrowest useful slice — `model/Harmony`, 19 files, which would give
  an oracle for **chord parsing and transposition**, §11.1's first two stated
  uses — needs Guava's `Preconditions`, `org.jjazz.utilities.api.ResUtil`, and
  the NetBeans `Lookup` that `ChordTypeDatabase.getDefault()` resolves through.

So the cost is: install Maven, then let it fetch the NetBeans platform and its
transitive dependencies. That is a system package and several hundred megabytes
of third-party binaries onto the human's machine, plus a new dev dependency that
§15 says needs an ADR. **Not something the agent should do unilaterally**, so it
has not been done, and this section is not ticked.

What stands in for it in the meantime, and what it does not replace:

| Oracle use | Covered today by | Gap |
| --- | --- | --- |
| Chord parsing | 2 516-case suite (M1) + 1 300 iReal Pro charts from the wild | No differential check against another implementation |
| Transposition | 2 520 cases through all twelve keys, with spelling assertions | Same |
| Chart flattening | Property tests: flattening preserves total bar count | Same |
| Generation | Determinism tests, music-theory assertions, human listening (§10) | This is the one a golden master would genuinely add to |

The honest summary: the parsing and transposition oracles would mostly confirm
what a large corpus already confirms, and the generation oracle — the one worth
having — is the one the missing toolkit blocks. **Say the word and it gets
built**; it is a toolchain decision, not an engineering one.

### 11.2 Layers

- **Domain:** pure unit tests, no Flutter. Fast, run on every save.
- **Property tests:** parse/format round-trips; transpose by n then by -n is identity; flattening preserves total bar count.
- **Music-theory assertions:** voicings satisfy stated rules; generated bass notes are chord tones on strong beats at a defined rate; drums never place two hits on the same instrument within 10 ms.
- **Audio null tests:** ✅ render offline, compare against a stored reference WAV within a sample-difference threshold. Catches synth regressions no listening test will. `rust/tests/audio_null_test.rs` against `tests/references/ii-v-i.wav`; threshold is two least-significant bits, and a 0.1% master-gain change — inaudible — fails it. Rules in `docs/rules/sf2-sampler.md` §10.
- **Golden image tests** ✅ for the chart renderer — Flutter's built-in golden files. Catches layout regressions instantly. `app/test/render/chart_golden_test.dart`.
- **Determinism test:** ✅ same seed ⇒ byte-identical MIDI output. This underpins every other test. Asserted across the generators, the exporters and the offline audio render.

### 11.3 Benchmarks

A `benchmarks/` suite run before each milestone sign-off, asserting the budgets in §3: generation time per song part, layout time per 100 bars, synth CPU at 64 voices, resident memory after loading a large bank under a mobile-sized budget, cold start. Append results to `docs/benchmarks.md` so regressions are visible across months rather than discovered on stage.

**Status: ✅ built** (2026-09-05). `benchmarks/run.sh`, driven by `just bench
"heading"`, which appends a dated section to `docs/benchmarks.md`. Every
benchmark lives beside the code it measures — a benchmark kept in a separate
tree stops being run and then stops compiling — and the runner is what drives
them together and writes the numbers down.

Four §3 budgets had never been measured before this. All four now are:

| Budget | Target | Hard | Measured |
| --- | --- | --- | --- |
| Layout, 100 bars | — | — | 1.0 ms (4.7 ms at 400) |
| Chart repaint, cursor frame | 4 ms | 8 ms | **0.012 ms** |
| Synth CPU, 64 voices | — | — | **8.4× real time** (2.9× at the 200-voice cap) |
| Cold start to library visible | 1 s | 3 s | **0.60–0.65 s** |

Measuring found a real defect. The layout was **O(bars × items)**: 100 bars took
2.23 ms and 400 took 24.38 ms — 13.8× the time for 4× the bars. `ChordLeadSheet`
answered `itemsInBarOfType`, `sectionAt` and `timeSignatureAt` by scanning every
item, and laying out one bar asked six such questions. Bucketing the items by bar
once at construction made it linear — 400 bars in 4.68 ms, five times faster —
and the MusicXML exporter and chart editor got the same fix. Nothing was slow at
32 bars, which is exactly the regression class §11.3 exists to catch.

Cold start is measured against the **real release binary**, timed from the
kernel's record of process start (`/proc/self/stat` field 22 against
`/proc/uptime`), because exec, dynamic linking and the Flutter engine's boot all
happen before `main` runs and a `Stopwatch` in Dart would miss most of what the
user waits for. Opt-in via `BANDSTAND_STARTUP_REPORT`; costs one map lookup
otherwise.

Timing budgets are asserted on **optimised builds only**. A debug build runs the
DSP about seven times slower — 68 voices at 1.1× real time rather than 8.4× —
which measures the optimiser and not the synth. The tests still run under `just
check` and still assert that the load is the one being claimed; only the
wall-clock bars are release-gated.

---

## 12. Repository layout

```plaintext
bandstand/
  app/                    Flutter application (package: bandstand)
    lib/
      domain/             harmony/ phrase/ song/ generation/
      render/             chart painter, layout
      io/                 importers/ exporters/ library
      ui/                 screens, widgets, theme
      bridge/             generated FFI bindings
    test/
    integration_test/
  rust/                   the bandstand-* crates from §7.1
  tools/
    oracle/               golden-master harness
    corpus_import/        MIDI + chord annotation → corpus JSON
  assets/
    chord_types.json
    corpora/
    fonts/
  docs/
    rules/                YOUR prose descriptions of algorithms (§1)
    format/               song JSON schema, corpus schema
    decisions/            ADRs — one file per significant choice
    benchmarks.md
  benchmarks/

# Reference trees live OUTSIDE the repo, at /home/vladimir/develop/refs/ (§14)
```

Tooling: `melos` if you split Dart packages; `cargo` workspace for Rust; `just` or a `Makefile` for the cross-language build. No CI needed for a personal project — a pre-commit hook running `dart test` and `cargo test` is enough.

### 12.1 Development environment (Ubuntu)

Concrete, because a broken toolchain is the most common early time sink:

- Flutter stable with Linux desktop enabled: `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`
- `libasound2-dev` for cpal (PipeWire is reached through its ALSA compatibility layer)
- Rust stable, plus `cargo-ndk` and the Android targets `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`
- Android SDK + NDK, with the NDK version matched to what `cargo-ndk` expects — mismatches surface as confusing linker errors
- `flutter_rust_bridge_codegen`, version-pinned; regenerate bindings with `just bridge`, never by hand
- `fluidsynth` CLI on the dev box, purely as the A/B reference for the sampler (§11)
- Reference trees stay at `/home/vladimir/develop/refs/`, outside the repo, so they cannot be committed or accidentally built

### 12.2 Project bootstrap

Run once, from the repo root. All platforms except web are scaffolded up front so that `flutter_rust_bridge_codegen integrate` configures every platform in a single pass — retrofitting a platform after the Rust integration means redoing its build configuration by hand.

```bash
mkdir -p ~/develop/bandstand && cd ~/develop/bandstand
git init

flutter create \
  --org dev \
  --project-name bandstand \
  --platforms=linux,android,windows,macos,ios \
  --android-language kotlin \
  --empty \
  --description "Chord charts, backing tracks and practice tools for working musicians" \
  app

cd app && flutter_rust_bridge_codegen integrate
```

Notes:

- **`--org dev`, not `--org dev.bandstand`.** The application id is `<org>.<project-name>` (§0).
- **No `web` in `--platforms`.** An absent `web/` directory is a stronger guarantee than a policy. Always pass `--platforms` explicitly on any later `flutter create` repair run, so web is never silently reintroduced.
- **`ios/` and `macos/` generate fine on Linux** — the Xcode project files are templates, not compiled artifacts. They cannot be *built* without a Mac. Treat them as untested scaffolding until M8; do not hand-edit them before then.
- After integration, restructure the single generated Rust crate into the `bandstand-*` cargo workspace from §7.1.
- `.gitignore` lives at the repo root, covering `app/build/`, `app/.dart_tool/`, `rust/target/` and generated bridge output.
- Pin the Flutter SDK version now (`fvm use <version>`, commit `.fvmrc`). Over a project this long, a Flutter upgrade that shifts Gradle or NDK expectations is a certainty.

---

## 13. Risk register

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Generated comping never sounds good enough to use | **Highest** | Corpus approach (§6.3); build corpus early; blind-test against real recordings; accept that this is permanent R&D |
| Sampler quality below FluidSynth | High | Null tests vs FluidSynth from M4; keep the option to bind libfluidsynth on desktop as a fallback |
| Mobile memory on large soundbanks | High | Design streaming into the sampler from the start (§7.2) |
| Chart layout edge cases eat months | Medium | Golden image tests; import 200 real charts early and fix what breaks |
| Scope creep into a DAW | Medium | The scope boundary: this app never records multitrack audio or edits waveforms |
| YamJJazz/CASM rabbit hole | Medium | Explicitly deferred to M9+; not required for the product to be useful |
| iOS signing friction | Low | Android first; iOS only if the iPad is your stage device |
| Motivation over a long solo build | **High** | Milestones ordered so M0–M5 produce a tool you use daily; ship to yourself constantly |

---

## 14. Reference index

### 14.1 JJazzLab — `/home/vladimir/develop/refs/JJazzLab/`

Consult freely to understand a concept, then **write the rule down in `docs/rules/` and implement from your own prose** (§1). Paths below are relative to the repo root; Java sources sit under `<module>/src/main/java/`.

| Concept | Path |
| --- | --- |
| Chord symbols, types, degrees, scales | `model/Harmony/src/main/java/org/jjazz/harmony/api/` |
| Notes, phrases, sized phrases, grid | `model/Phrase/src/main/java/org/jjazz/phrase/api/` |
| Lead sheet, song structure, song parts, sections | `model/Song/src/main/java/org/jjazz/` (`chordleadsheet/`, `songstructure/`, `song/`, `midimix/`) |
| Rhythm / voice / parameter abstractions | `model/Rhythm/src/main/java/org/jjazz/rhythm/api/` |
| Generation pipeline, chord sequences | `core/RhythmMusicGeneration/src/main/java/org/jjazz/rhythmmusicgeneration/api/` |
| Accents, anticipated chords | same package — `AccentProcessor.java`, `AnticipatedChordProcessor.java`, `SongSequenceBuilder.java` |
| Humanization | `core/Humanizer/src/main/java/org/jjazz/humanizer/api/` |
| Phrase transforms, quantization | `core/PhraseTransform/`, `core/Quantizer/` |
| Importers: MusicXML, Impro-Visor, BIAB, text | `core/Importers/src/main/java/org/jjazz/importers/api/` |
| **Repeat / ending / D.S. / coda resolution (§4.5)** | `core/Importers/src/main/java/org/jjazz/importers/musicxml/` — `BarNavigationIterator`, `NavigationMark`, `CLI_Repeat`, `CLI_Ending` |
| **Corpus tiling — the key idea (§6.3)** | `plugins/JJSwing/src/main/java/org/jjazz/jjswing/bass/` — `WbpSource`, `WbpSourceSlice`, `WbpTiling`, `Tiler*`, `WbpsaScorer`, `BassGenerator`, `db/WbpSourceDatabase` |
| Corpus data format (MIDI phrase DB) | `plugins/JJSwing/src/main/resources/org/jjazz/jjswing/bass/db/*.mid`, `drums/db/drums44DB.mid` |
| Drum generation | `plugins/JJSwing/src/main/java/org/jjazz/jjswing/drums/` |
| Yamaha SFF1/SFF2 + CASM (deferred, M9+) | `plugins/YamJJazz/src/main/java/org/jjazz/yamjjazz/` — `CASMDataReader.java`, `rhythm/api/YamJJazzRhythmGenerator.java`, `CtabChannelSettings.java`, `Ctb2ChannelSettings.java` |
| MIDI device / instrument bank modelling (mostly N/A) | `model/Midi/src/main/java/org/jjazz/midi/api/` (`synths/`, `keymap/`, `device/`) |

**Not useful, do not read:** `app/` (81k lines of NetBeans Swing UI), `core/EmbeddedSynth/.../lame/` (bundled MP3 encoder), `core/Guava`, `core/Xstream`, `core/FlatComponents`, `core/UIUtilities`.

### 14.2 Wim Vree tools — `/home/vladimir/develop/refs/vree/`

**Out of scope by default.** Do not search this tree unless the current task is the MusicXML importer and the human has said so. Contents include `xml2abc` (both `xml2abc_python` and `xml2abc_javascript`), `abc2xml`, `abcweb`, `xmlplay`, `synpdf`, `audsync`, `follow`.

| When it is relevant | What to look at |
| --- | --- |
| Writing the MusicXML importer (M2/M5) — real-world deviations from spec across Sibelius, Finale, MuseScore output: divisions, ties, tuplets, voltas, repeat encodings | `vree/xml2abc_python/` (preferred — clearer than the JS port); cross-check `vree/xml2abc_javascript/` only if a behaviour is unclear |
| Writing the MusicXML **exporter** | `abc2xml` |
| *If* audio-to-chart alignment ever returns to scope (currently a non-goal) | `audsync` — tempo estimation, beat tracking, score alignment |
| *If* live score following ever returns to scope (currently a non-goal) | `follow` — online alignment of MIDI input to a score |

Caveat when reading these: terse single-author Python/JavaScript with very short identifiers, the sort of code an LLM transliterates confidently and wrongly. Extract *rules*, never lines. Note also that these are concerned overwhelmingly with **notes**, because ABC is a note format — most of that knowledge is irrelevant until and unless melody display is added.

External references:

- iReal Pro format: `irealpro.com/ireal-pro-file-format/`; implementations `pyRealParser`, `ireal-reader`, `Data-iRealPro`, `ireal_parser` (Rust crate)
- SoundFont 2.04 specification
- Yamaha SFF1/SFF2 style format documentation
- MusicXML 4.0 specification, and the **Unofficial MusicXML Test Suite** (~130 test files) as an importer acceptance corpus
- Oboe (Android audio), `AVAudioSession` (iOS)

---

## 15. Working agreement for the coding agent

- Read `docs/decisions/` before proposing architecture changes; add an ADR when making one.
- Domain code has no Flutter imports. Audio code has no UI concepts. Enforce with a lint.
- No new dependency without an ADR justifying it. The point of this project is owning the stack.
- Every algorithm gets a prose description in `docs/rules/` before implementation.
- Every bug fix gets a regression test first.
- Prefer data over code: chord types, styles, corpora and voicings are assets, not `switch` statements.
- Keep the FFI surface small. Adding a function to the bridge requires justification.
- When stuck on musical judgement, stop and ask the human. Aesthetic decisions are not the agent's to make.
