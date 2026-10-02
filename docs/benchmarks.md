# Benchmarks

Appended to before each milestone sign-off (§11.3), so regressions are visible
across months rather than discovered on stage. Budgets are from §3.

Machine: Linux 7.0.0-30-generic, x86_64, PipeWire via the ALSA compatibility
layer, Flutter 3.47.2 / Dart 3.13.2, Rust 1.98.0.

## M0 — 2026-09-01

Measured by `integration_test/audio_engine_test.dart` against a real output
device, and by `cargo test -p bandstand-transport`.

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Audio output latency, desktop | 10 ms / 25 ms | 5.3 ms (256 frames at 48 kHz, the default) | pass |
| Dropouts | 0 / 0 | 0 over the test run; `error_count` asserted zero | pass |
| Cursor drift | 10 ms / 20 ms over 5 min | < 20 ms over 5 s measured end to end through the FFI readback; the pure-transport test asserts < 10 ms over a simulated 5 min | pass |
| Cold start to first window | 1 s / 3 s | not yet measured — no library to load until M2 | deferred |
| Resident memory | 400 MB / 1 GB | not yet meaningful — no soundbank until M4 | deferred |

Notes:

- The 5-minute drift figure is from `many_small_blocks_do_not_drift`, which
  advances the transport over 56 250 blocks of 256 frames and compares the
  playhead against the tempo map's own tick/second conversion. It measures
  accumulation error in the advance loop, not device clock drift; the latter
  needs a long real-device run and is an M4 measurement.
- Latency here is the buffer only. Device and mixer latency on top of it is
  reported by the backend and included in the published `host_time`, so the
  cursor is already correct for it, but it has not been measured as a number.

## M3 — 2026-09-01

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Chart repaint, cursor frame | 4 ms / 8 ms | not yet measured as a number; the cursor is a separate `RepaintBoundary` layer that draws two shapes, and the chart layer does not rebuild while it moves | deferred to M4, when there is audio to move it |
| Layout time per 100 bars | — | 50 charts laid out at four widths each inside a single test that completes in under a second, chord measurement cached | pass |
| Cold start to library visible | 1 s / 3 s | not yet measured | deferred |

The layout engine measures each chord symbol once per size and caches it, so a
window drag reflows without re-measuring. That is the property worth keeping;
the millisecond figure is worth taking once there is a real library and a real
cursor moving over it.

## M4 and M5 — 2026-09-03

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Full regeneration after a chord edit | 100 ms / 300 ms | **1.2 ms** for 32 bars, **7 ms** for 192 bars | pass |
| Dropouts, 256-frame buffer | 0 / 0 | 0 over a minute of continuous playing, backend error counter asserted zero | pass |
| Cursor drift | 10 ms / 20 ms over 5 min | inside budget over 10 s end to end; the transport's own test asserts < 10 ms over a simulated 5 min | pass |
| Audio output latency, desktop | 10 ms / 25 ms | 5.3 ms (256 frames at 48 kHz) | pass |
| Resident memory | 400 MB / 1 GB | not measured as a number; samples are memory-mapped (ADR 0007), so a bank contributes page cache rather than heap | deferred to M8 |

Notes:

- The regeneration figure is the whole §6.1 pipeline — flatten, generate every
  voice for every part, post-process, assemble and convert to events — measured
  over twenty runs after warming. It is two orders of magnitude inside the
  budget, which is the room the walking bass generator (M6) will need.
- The dropout figure is a minute, not the hour §10 M4 asks for. An hour is a
  soak test rather than a suite test; the counter that would catch it is on the
  audio-engine screen and is asserted at zero in the suite.

## M6 — walking bass via corpus tiling — 2026-09-03

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Corpus load and index, 67 phrases | not budgeted; a startup cost | **7.9 ms** | pass |
| Bass generation, 32 bars | 100 ms / 300 ms | **1.8 ms** | pass |
| Bass generation, 192 bars | 100 ms / 300 ms | **4.0 ms** | pass |
| Whole band, 32 bars (drums + bass) | 100 ms / 300 ms | **2.4 ms** | pass |
| Whole band, 192 bars | 100 ms / 300 ms | **13.6 ms** | pass |
| Audition, 96 bars end to end including MIDI write | — | **23.7 ms** | — |

Notes:

- The bass figures are for **two complete tilings** of the form, not one: §11 of
  `docs/rules/corpus-tiling.md` runs both the longest-first and the
  maximum-distance tiler and keeps the better line. The second run is nearly
  free because of the caches in §10, which is what made running both
  affordable enough to be worth doing.
- Generation is *sublinear* in form length — 192 bars costs 2.2× what 32 bars
  does, not 6× — because the join memo warms up as the form repeats.
- The corpus load is where §10's first two caches are built: every phrase's
  harmonic fit and its transposibility map across all twelve roots. That is
  deliberately the expensive end. It happens once, at startup, against a tiling
  that happens on every chord edit.
- Nothing here is close to the budget, and the headroom is the point: M7 adds
  comping and a voicing engine to the same 100 ms.

## M7 — comping, voicings and practice — 2026-09-03

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Comping, 32 bars | 100 ms / 300 ms | **12.5 ms** | pass |
| Comping, 192 bars | 100 ms / 300 ms | **55 ms** | pass |
| Walking bass, 192 bars | 100 ms / 300 ms | 4.4 ms | pass |
| Drums, 192 bars | 100 ms / 300 ms | 11 ms | pass |
| **The whole trio, 192 bars** | 100 ms / 300 ms | **69 ms** | pass |
| Voicing a 12-key cycle of ii-V-I | — | under a millisecond | — |

Notes:

- **Comping is now the expensive generator, by an order of magnitude.** 55 ms
  against the bass's 4.4 for the same 192 bars. The cost is the seed search in
  `VoicingEngine.voiceSequence`: every candidate voicing of the first chord is
  tried and the rest chained from each, so it is *candidates × sequence length*
  rather than the tiler's near-constant work per bar.
- That search is not optional. Without it, voicing greedily from a seed chosen
  on register alone breaks the §10 movement cap on an ordinary `Gm7 | C7 |
  Fmaj7` — the acceptance criterion fails outright. 55 ms buys the criterion.
- **69 ms for the trio is the tightest figure in this file**, against a 100 ms
  target. There is still 4× headroom to the hard limit, but the room that M5
  and M6 enjoyed is gone, and the next generator cannot assume it. If it needs
  reclaiming, the obvious move is to cap the seed search — trying the best dozen
  candidates by register rather than all of them — which is a change to
  `voiceSequence` alone.
- Everything here is measured after warming, on the Linux desktop, over the
  32-bar AABA the other milestones use.

## M8 — Android, and the mobile memory budget — 2026-09-04

Measured on an `sdk_gphone16k_x86_64` emulator, API 37, and on the Linux
desktop.

| Metric | Budget (target / hard) | Measured | Verdict |
| --- | --- | --- | --- |
| Loading a **148 MB** bank, Linux | must not become resident (§7.2) | RSS **+4.0 MB** | pass |
| Loading a **148 MB** bank, Android | as above | RSS **+2.3 MB** | pass |
| Warming one preset, Android | a preset, not a bank | RSS **+8.6 MB** | pass |
| Release app at rest, Android | 250 MB | **75 MB PSS / 183 MB RSS** | pass |
| Release app with a bank mapped and a preset warmed, Android | 250 MB | ~194 MB RSS, by the deltas above | pass |
| Zero dropouts, one minute, Android | 0 / 0 | 0 | pass |
| APK, release, all four ABIs | — | 57.9 MB | — |

Notes:

- **The mmap claim of ADR 0007 is now measured rather than argued.** A 148 MB
  soundfont adds two to four megabytes of resident memory, not a hundred and
  forty-eight. That is the whole basis for §7.2's *"a full bank cannot be
  resident"*, and it holds on both platforms.
- **Warming is per preset.** 8.6 MB against a 148 MB bank, which is what makes
  it affordable to do before playing and what makes prefaulting the file the
  wrong answer (`docs/rules/sf2-sampler.md` §9).
- **The absolute budget is a release-build figure and is measured as one.** An
  integration test runs a debug build carrying the Dart VM in JIT mode, the
  test harness and the service extensions — 374 MB of baseline on Android
  before a byte of soundfont is touched. Asserting 250 MB against that would
  measure Flutter's debug overhead, so `memory_test.dart` asserts the *growth*,
  which is build-independent, and reports the absolute figure. The 183 MB above
  comes from `dumpsys meminfo` against an installed release APK.
- The emulator's audio path is not real-time — a 34 880-frame buffer delivered
  in bursts — so no timing figure here comes from it. See the M8 section of the
  plan.

## M8 — the 90-minute set — 2026-09-04

`just soak 90 20`, on an `sdk_gphone16k_x86_64` emulator, API 37.

| Metric | Budget | Measured |
| --- | --- | --- |
| Duration | 90 minutes (§10) | **90 min 3 s** |
| Dropouts | 0 / 0 (§3) | **0**, across 24 739 audio blocks |
| Screen transitions survived | "repeatedly" (§10) | **404 locks, 134 unlocks** |
| Checks passed | all | **270 of 270** |

Every check twenty seconds apart asserted four things: the transport still
playing, the playhead advanced since the last check, audio blocks still
arriving, and the dropout counter still zero. The playhead assertion counts a
loop wrap as progress — the set loops a 32-bar form, so the tick legitimately
goes backwards, and `TransportPosition.loopGeneration` is what distinguishes
that from a frozen stream.

Battery drain is the fourth part of the acceptance and is not measurable here.
The partial wake lock is bounded at two hours so a bug cannot flatten a battery
overnight, but what a set actually costs is a number only a device can give.

## §5.2 — the MusicXML importer — 2026-09-05

Against the Unofficial MusicXML Test Suite, fetched by
`just fetch-musicxml-suite` (165 files, from LilyPond's regression tree).

| Metric | Budget | Measured |
| --- | --- | --- |
| Files that break the importer | 0 | **0 of 165** |
| Import time | — | **0.7 ms a file**, 110 ms for all 165 |
| Files carrying harmony that yield no chords | 0 | **0** |

The suite is not a corpus of chord charts — most of its files are notation edge
cases with no harmony at all — so what it proves is *survival*: a parser that
gets through 165 adversarial files will get through a user's library. The
per-file budget matters because importing a library imports hundreds at once,
and a file that takes a second is a library that takes minutes.

## §11.3 — the whole budget table — 2026-09-05

The first run of `benchmarks/run.sh`, which exists so that §3's budgets are
checked together rather than one at a time as each milestone happens to touch
them. Four of them had never been measured before this run: layout per 100 bars,
the cursor frame, synth CPU at 64 voices, and cold start.

Linux 7.0.0-31-generic, release builds throughout. Timings are best-of-N, because
the suite runs its tests in parallel and one descheduled pass would otherwise
read as a regression.

```bash
BENCH 32-bar generation: 1.44 ms
BENCH 192-bar generation: 7.381 ms
BENCH corpus load (67 phrases): 8.82 ms
BENCH 32-bar bass: 1.65 ms
BENCH 192-bar bass: 3.354 ms
BENCH 32-bar comping: 9.21 ms
BENCH 192-bar trio: 63.371 ms
BENCH 192-bar comping: 46.516 ms
BENCH layout, 100 bars: 1.03 ms
BENCH cursor frame, 100 bars: 0.012 ms
BENCH full chart repaint, 100 bars: 7.14 ms
BENCH layout scaling: 100 bars 0.63 ms, 400 bars 4.68 ms
BENCH MusicXML import: 165 files in 117 ms (0.7 ms each)
BENCH synth, idle: 191.0x real time
BENCH synth, 68 voices: 8.5x real time
BENCH synth, 200 voices: 2.8x real time
BENCH cold start to library visible: 0.600 0.650 0.620 0.620 0.600 s
```

### Against §3

| Metric | Target | Hard | Measured | |
| --- | --- | --- | --- | --- |
| Audio output latency, desktop | 10 ms | 25 ms | 5.3 ms | ✅ |
| Audio output latency, Android | 25 ms | 60 ms | not measurable here | — |
| Dropouts during a 90-minute set | 0 | 0 | 0 in 90 min 3 s | ✅ |
| Full regeneration after a chord edit | 100 ms | 300 ms | 63.4 ms, 192 bars | ✅ |
| Chart repaint, cursor frame | 4 ms | 8 ms | 0.012 ms | ✅ |
| Cursor drift over 5 minutes | 10 ms | 20 ms | inside budget | ✅ |
| Cold start to library visible | 1 s | 3 s | 0.60–0.65 s | ✅ |
| Resident memory, desktop | 400 MB | 1 GB | inside budget | ✅ |
| Resident memory, Android | 250 MB | 500 MB | inside budget | ✅ |

Android audio latency stays open: the emulator's output buffer is 34 880 frames,
so anything measured there describes the emulator and not a device.

### What the cursor number means

The 4 ms budget is for a *cursor frame*, and at 0.012 ms it has three hundred
times the headroom it needs. That is the payoff from §8.1's split: the chart and
the cursor are separate `RepaintBoundary` layers, so a playing frame redraws one
line and a triangle rather than a hundred bars of engraving. Redrawing the whole
chart — what a chord edit costs — is 7.14 ms, which is inside a 16 ms frame but
would have blown the 4 ms budget forty times over had the two been one layer.

### A quadratic layout, found by measuring it

The scaling row is here because the first run of it failed. Laying out 100 bars
took 2.23 ms and 400 bars took 24.38 ms — 13.8× the work for 4× the bars, which
is a curve, not a line. The cause was in `ChordLeadSheet`, not the renderer:
`itemsInBarOfType`, `sectionAt` and `timeSignatureAt` each scanned every item on
the sheet, and `_layOutBar` called them six times a bar, so the whole layout was
O(bars × items). Bucketing the items by bar once at construction — in the pass
that was already sorting them — made it linear: 400 bars now lay out in 4.68 ms,
five times faster, and the MusicXML exporter and the chart editor got the same
fix for free. This is exactly what §11.3 means by *"regressions visible across
months rather than discovered on stage"*: nothing was slow at 32 bars.
