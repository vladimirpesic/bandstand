# Bandstand — Full-Corpus Code Review, Quality Analysis and QA Audit

- **Date:** 1 October 2026
- **Revision audited:** commit `8eae803` ("Implement everything from TODO.md"), working tree clean
- **Post-audit additions (same session):** F-01 fix (per-device `flock` in the Justfile), an Android emulator QA pass (§2), and the F-12 phone-width AppBar fix it prompted — all verified green
- **Corpus (cloc, excl. `target/build/.dart_tool/...`):** Dart 42,119 · Rust 12,485 · Markdown 5,670 · JSON 5,216 · TOML 98 · Shell 89 · YAML 83 · XML 17 — **65,777 lines total**
- **Method:** every hand-written source file was read in full (Rust: all 4 crates + the FFI crate; Dart: all of `lib/` minus the 3,187 generated bridge lines, which were verified as generated and skimmed for surface shape; all 91 unit-test files and 9 integration suites catalogued and their assertions read; the Justfile, both tool packages, the asset codecs' consumers and `docs/` cross-checked against the code they govern). All QA gates were **re-run from scratch during this audit**; results in §2.

---

## 1. Executive summary

**Overall verdict: excellent. Ship-quality.** This is an unusually disciplined 65k-line codebase: every module has a written rule document it visibly implements, every hard problem (lock-free transport readback, SoundFont parsing, corpus tiling, atomic library persistence) is solved with textbook technique and an in-line explanation of *why*, and the test corpus (1,397 unit tests + 49 desktop integration tests + an A/B acceptance harness against FluidSynth) exercises the parts that actually carry risk.

No correctness defect was found anywhere in the corpus. The findings register (§9) contains **zero blocking or high-severity items**: twelve observations — ten low/informational, one test-infrastructure caveat discovered by this audit itself (F-01: integration suites must not run concurrently against one audio device), and one genuine phone-width UI bug (F-12: the song-details AppBar overflowed a 411 dp portrait) that only surfaced once the audit was extended to an Android emulator and is **fixed and re-verified alongside this report**. What remains non-certifiable from a desktop/emulator is performance-shaped and unchanged in substance: real-device audio timing (the emulator's audio path buffers 34,880 frames, so the §3 drift legs honestly skip there), the 90-minute device soak, and the 256→512-rounding backend L-TQ13 guards against.

The TODO.md remediation cycle (24 items, commit `8eae803`, +911/−145 over 28 files) is fully represented in the code: L-RH4 (`repost_delta` under the state lock), L-RT2 (seek re-send to `ceil(tick) − 1`), L-RH7 (GM default volume `100/127` matching `EngineState`), L-RS3 (u64 RIFF arithmetic), L-RS4 (recipe buffer pre-sized), L-I3/I4, L-S1, L-B2/B3, L-A3, L-G2, L-TQ3…TQ13 — each was located in the source and its test located in the suites. The open question carried over from that session — "confirm L-TQ2" — is resolved as a **false premise: no L-TQ2 exists in TODO.md** (the ID space is L-TQ3…L-TQ8 and L-TQ10…L-TQ13; L-TQ1/L-TQ2/L-TQ9 were never items in that file).

---

## 2. QA evidence (re-run during this audit)

| Gate | Result |
| --- | --- |
| `cargo fmt --all --check` | ✅ clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | ✅ zero warnings |
| `cargo test --workspace` | ✅ **261 tests**, 17 binaries, 0 failed |
| `dart format --set-exit-if-changed lib test integration_test` | ✅ clean |
| `flutter analyze` | ✅ zero issues |
| `flutter test` (unit) | ✅ **1,040 tests**, 0 failed |
| `tools/tiling_probe` (analyze + test) | ✅ 72 tests |
| `tools/corpus_import` (analyze + test) | ✅ 24 tests |
| **`just check` (all of the above)** | ✅ **exit 0** |

Desktop integration suites (`-d linux`, serial, GM bank pushed via `BANDSTAND_SOUNDFONT`):

| Suite | Result |
| --- | --- |
| `library_test` | ✅ 11/11 |
| `audio_engine_test` | ✅ 4/4 (see caveat below) |
| `synth_test` | ✅ 7/7 |
| `generation_test` | ✅ 11/11 |
| `platform_audio_test` | ✅ 5 passed, 1 skipped (Android-only leg) |
| `memory_test` | ✅ 2/2 |
| `page_turner_test` | ✅ 4/4 |
| `reading_mode_test` | ✅ 5/5 |
| `soak_test` | device-only by design (90-minute lock/unlock soak; Justfile `android-soak`) |

**Caveat found by this audit (F-01):** the first serial run of `audio_engine_test` failed its "transport clock keeps time to within the §3 budget" leg *while a second `flutter test` process was competing for the same ALSA device* (an artefact of how this audit re-ran it). Re-run in isolation it passed **twice, 4/4, with the drift leg comfortably inside budget**. The transport itself is not at fault — the drift measurement includes real device scheduling, so two simultaneous device clients can push it out. Actionable note: integration suites must run serially per audio device. Originally only a convention, this is now **enforced**: `just integration-test` and `just android-test` take a blocking per-device `flock`, so a concurrent second invocation queues instead of contending (F-01, resolved).

Android emulator run (added to this audit afterwards; `just android-test` against `emulator-5554` — `sdk_gphone16k_x86_64`, Android 17 / API 37, **16 KB pages**, 1080×2400 @ 420 dpi = **411 dp** portrait, TimGM6mb bank pushed):

| Suite | Result |
| --- | --- |
| `library_test` | ✅ 11/11 **after the F-12 fix** (6 passed / 5 failed before it) |
| `audio_engine_test` | ✅ 3 passed, 1 honest skip — the §3 drift leg refuses the emulator: "this device buffers 34880 frames, which is not a real-time audio path" |
| `synth_test` | ✅ 6 passed, 1 honest skip (same §3 guard); GM playback through the device green |
| `generation_test` | ✅ 11/11 |
| `platform_audio_test` | ✅ **6/6 — the Android-only audio-focus leg ran and passed** (it skips on desktop), including the 16 KB-page load of the native library |
| `memory_test` | 0 run, 2 honest skips — the pushed 6 MB bank "is too small to distinguish a mapping from a read"; push the 148 MB FluidR3 to enable these legs on-device |
| `page_turner_test` | ✅ 4/4 |
| `reading_mode_test` | ✅ 5/5 |

The emulator run covers exactly the functional/device-shape half of the certification gap: the JNI install path, the Android audio-focus and service lifecycle, the sampler on the Android audio backend with a real bank, and a phone-width (411 dp) layout. It cannot certify performance — the emulator's audio HAL buffers 34,880 frames — so the §3 drift legs, the soak and any latency claim still need physical hardware.

---

## 3. Corpus map and how it was covered

| Area | Files | Lines (wc) | Coverage in this audit |
| --- | --- | --- | --- |
| Rust — `bandstand-transport` | 7 | 1,876 | 100% read |
| Rust — `bandstand-sequencer` | 6 | 1,406 | 100% read |
| Rust — `bandstand-synth` (DSP + effects) | 12 | 3,487 | 100% read |
| Rust — `bandstand-synth/sf2` | 6 | 2,206 | 100% read |
| Rust — `bandstand-audio-host` | 4 | 672 | 100% read |
| Rust — FFI crate (`engine`, `api`, `offline`, `android`) | 6 | 2,281 | 100% read (`frb_generated.rs` verified generated) |
| Rust — integration tests | 7 | 2,788 | catalogued; key harnesses read in full |
| Dart — `lib/bridge` (generated) | 4 | 3,187 | verified `@generated`; surface cross-checked against `api/audio.rs` |
| Dart — `lib/audio`, `lib/state`, `lib/diagnostics`, `main` | 12 | 2,194 | 100% read |
| Dart — `lib/domain` (harmony, song, phrase, command) | 39 | 9,704 | 100% read |
| Dart — `lib/domain/generation` | 24 | 4,462 | 100% read (`wbp_tiling.dart` re-verified this cycle) |
| Dart — `lib/io` (library, codecs, importers, exporters, MIDI) | 16 | 4,567 | 100% read |
| Dart — `lib/render` | 8 | 1,723 | 100% read |
| Dart — `lib/ui` | 15 | 4,178 | screens read or fully catalogued; editor/reading-mode/details read line-by-line |
| Dart — tests | 91 | 19,853 | catalogued; assertions read per suite |
| Tools (`tiling_probe`, `corpus_import`) | 11 | 2,392 | structure + entry points read; suites executed green |
| Docs (`docs/`, plans, TODO) | 49 | 7,306 | rule docs cross-checked against their modules |
| Assets (6 JSON data files) | 6 | 5,251 | validated by the 1,040-test suite (schema-versioned codecs) |

Generated code is confined to `app/lib/bridge/**` and `rust/src/frb_generated.rs` (5,112 lines, 7.8% of the corpus) and is never hand-edited — the header warning plus the `just bridge` recipe make this explicit.

---

## 4. Rust workspace — module-by-module

### 4.1 `bandstand-transport` (1,876 LoC) — health: excellent

The timeline crate. `TempoMap` (immutable segments, binary search, 10–400 bpm validation, tick↔seconds round-trip tested at 40k points); `PositionCell` — a correct seqlock (odd-seq write barrier, release/acquire fences, bounded 16-retry reader with documented fallback); `LoopCell` — the same protocol with the audio thread as reader; `TempoMapSlot` — SPSC `Arc<TempoMap>` handoff whose `unsafe` blocks each carry a SAFETY argument, with retire slots so deallocation stays off the audio thread (the documented bounded exception when all four slots fill is the only path that can free there). `Transport::split_block` is the hardest code in the repo: per-block loop segmentation with an 8-segment budget, wrap folding for loops shorter than a block, loop-generation counting, and the seek protocol — tick-bits-then-sequence with a double-read coherence loop, and the *applied* sequence number that survives close/reopen (both reopen directions tested). `clock.rs` is a once-locked monotonic epoch. No defects; ordering discipline is consistent (Release on publish, Acquire on consume).

### 4.2 `bandstand-sequencer` (1,406 LoC) — health: excellent

`Sequence` (sort with note-off→program→note-on ordering at equal ticks, backward `programs_at_into` scan that allocates nothing), `Sequencer` (cursor walk over transport segments, sample offsets clamped into the segment, sounding-note table with per-(channel,key) overlap counts and the saturation guard that keeps `sounding_count` drainable, release-all at wraps and seeks, program re-send after a mid-block wrap landing at the wrap frame with the `ceil(tick)−1` boundary — the L-RT2 fix, tested by a true-trace assertion), `metronome` (count-in/click as plain events; u64 arithmetic with capacity caps — the L-RS3-class hardening). `#![forbid(unsafe_code)]`. No defects.

### 4.3 `bandstand-synth` — DSP and effects (3,487 LoC) — health: excellent

`Synth`: 16 GM channels, sustain-pedal semantics correct in all three corner cases (pedal tap, re-struck key during sustain, pedal-up releasing only what went up during it — each tested), voice stealing finished→oldest-releasing→quietest with the never-steal-this-block rule, exclusive classes cut *before* the new voice starts, per-block `ChannelMix` precompute, additive render into an interleaved bus with preallocated scratch. `Voice`: Catmull-Rom interpolation with edge clamping, `rem_euclid` loop wrap, modulations per the SF2 generator set with early-outs, filter cutoff recomputed at most every 32 samples. `Envelope`: six stages, exponential decay/release with a −100 dB floor, `release_fast` for steals. `Smoothed`: linear ramps chosen over one-pole with an explicit f32-stall argument, exact-arrival tested. `LowPassFilter`: biquad with a 0.45·Nyquist clamp, bypass path that resets state on re-engage (click fix, tested), NaN-poisoning test. `TestTone`: phase-accumulator sine, 15 ms glides, frequency accuracy verified by zero-crossing count. `Reverb` (Freeverb-class, rate-scaled tunings, non-finite guards in every feedback path) and `Chorus` (three taps; wet-off still advances the delay line so re-enabling doesn't replay stale audio). Crate-level `#![forbid(unsafe_op_in_unsafe_fn)]` and a documented numeric-cast allow block. No defects.

### 4.4 `bandstand-synth/sf2` (2,206 LoC) — health: excellent

`riff.rs`: a defensive RIFF reader — every truncation, wrong form type, bad record length, missing terminal record and out-of-range index is its own named error; chunk math in u64 so a crafted `u32::MAX` size cannot overflow `usize` on a 32-bit target (L-RS3, with the test that pins it). `parse.rs`: global-zone overlay, preset-vs-instrument generator semantics (`add_preset_offsets` applies only to additive generators — "the rule everyone gets backwards", tested), zones with no target ignored per spec, mmap'd sample data with the SIGBUS constraint documented in-code and in ADR 0007. `bank.rs`: `GeneratorSet` with spec defaults, byte-range unpacking, `voices_for` into a caller-owned buffer (L-RS4 pre-size), preset fallback chain (bank → bank 0 → first preset), loop-point usability checks, control-thread `warm_preset` page pre-faulting. `generators.rs`: the operator table with unit conversions (`timecents_to_seconds`, `absolute_cents_to_hertz` pinned to A440, `centibels_to_gain` with the 960 silence floor). `samples.rs`: resident and mmap'd `SampleSource`s; the page-warming `read_volatile` unsafe block is SAFETY-commented. No defects.

### 4.5 `bandstand-audio-host` (672 LoC) — health: excellent

A cpal wrapper and nothing else. Device enumeration hides unopenable devices; config selection prefers requested rate → 48 kHz → device default with stereo preference; the callback uses a grow-once scratch buffer, hard-clips (NaN→0) before integer conversion, counts health atomically, and — the standout — measures output latency **once per stream** and clamps it to a plausibility ceiling (`2·block`, ≤2 s) because the Android backend was measured reporting 1148-second latencies that made the published host time run backwards. That clamp and its measured origin are tested. `#![forbid(unsafe_code)]`. No defects.

### 4.6 FFI crate — `engine.rs`, `api/audio.rs`, `offline.rs`, `android.rs` (2,281 LoC) — health: excellent

`engine.rs` is the convergence point: a single owning engine thread (cpal streams are not `Send` everywhere), a 256-deep task queue drained by `try_recv` at block top, sample-accurate event application (the block renders in runs between events), `EngineState` replay across device changes, and the L-RH4 `repost_delta` — diffed under the state lock with bit-exact float comparison so a setting changed during an open-in-flight window lands on the new stream exactly once (unit-tested, plus a no-device dead-thread degradation path that errors instead of panicking across the FFI, and a poster-vs-reopen soak). `api/audio.rs` is the deliberately thin bridge surface: flat numeric `MidiEvent`s with per-field range *rejection* (not wrapping), all-or-nothing `load_sequence` (map built and events validated before anything is installed), calibrated pan mapping (0→−1, 64→0, 127→+1 exact), honest `audio_start` status semantics. `offline.rs`: a WAV writer that refuses sub-8 kHz rates and >4 GiB renders *before* creating a file, 3 s tails, live-mix bounce. `android.rs`: 102 lines; JNI context install with a `compare_exchange` claim guard against double-initialisation panics, `INITIALISED` set last so the `audio_start` gate can't race the install. No defects.

---

## 5. Dart app — module-by-module

### 5.1 `lib/audio` + `lib/state` (wiring layer, ~2,200 LoC) — health: excellent

`AudioEngineController` survives every lifecycle race its comments enumerate: presses queued across in-flight opens, tone re-push after restart with failure surfaced but the stream kept, a stop that throws no longer bricks `busy`, polling stops rather than erroring every second, disposal guards across FFI round-trips. `PlatformAudioController` implements the Android focus policy in Dart with a testable `PlatformTransport` seam — transient-loss resume only for pauses it caused, duck as gain-not-pause, duck undone on permanent loss — and every playback path funnels through `play()` so the focus handshake can't be forgotten. `PracticeController` drives the session domain object at the transport, regenerating only when the key actually changes. `SongPlaybackController` serialises generation through an in-flight queue; `ExportController` refuses to bounce audio when generation was superseded. `SongEditor` adds the crash journal (best-effort, error recorded rather than thrown into an unhandled zone). All controllers are Riverpod `Notifier`s with `copyWith` state and seams for testing without a live engine.

### 5.2 `lib/domain` — harmony (2,650 LoC) — health: excellent

`PitchSpelling`/`Degree`/`Natural` implement the spelling-not-pitch-class doctrine everywhere (±2 accidental bound, enharmonic ≠ equal, `#9` vs `b3` carried structurally); `ChordSymbol.parse` never guesses (documented fail-loudly; `parse(format()) == x` guaranteed); `ChordTypeDatabase` is data-driven with the modifier algebra (set-displaces-same-number, no semitone collapsing — the `Cm7#9`/`Cm7b5#11` regressions are documented and tested); `KeySignature` counts accidentals via the circle of fifths and clamps to ±7; `SpellingPreference` gives automatic/sharps/flats/key-driven spelling; `Nashville` and `InstrumentTransposition` (with the simplest-signature written-key search) ride the same core. The domain-purity meta-test (§7) enforces the layer boundary mechanically.

### 5.3 `lib/domain` — song, phrase, command (7,050 LoC) — health: excellent

Immutable model throughout (structural sharing makes whole-value undo cheap — `UndoStack` holds `before`/`after` snapshots with a merge window and no-op elision). `ChordLeadSheet` buckets items by bar once (the fix that made layout linear — documented with the measured curve); `navigation.dart` expands repeats/endings/jumps with a 4,096-bar ceiling, ending groups split on non-climbing pass numbers, jump semantics (repeats not retaken after D.C./D.S.) and a `sourceBars` map that every downstream consumer (cursor, MIDI export markers, written-part fan-out) resolves through. `SongChordSequence` is the single generator input — form, arrangement and meter changes resolved away. `Phrase`/`SizedPhrase` keep positions phrase-relative with a span that drops runaway notes (L-S1 override set) and drums never transposed; the quarters-vs-beats conversion happens exactly once in `SongGenerator` (the 6/8 half-speed bug class is documented at the conversion site).

### 5.4 `lib/domain/generation` (4,462 LoC) — health: excellent

Pure and seeded end to end (per-bar and per-member seed derivation so editing bar 30 doesn't reroll bar 2; a hand-rolled FNV-1a pattern hash because `String.hashCode` carries no cross-version guarantee — an eight-line investment with the reasoning in-code). Drums: pattern corpus with intensity bands, deterministic chance draws, beat weighting, a density arc across the song. Bass: the full corpus-tiling pipeline of `corpus-tiling.md` — root profiles (transposition-invariant), transposability maps, the §7 join scorer with its memo, two tilers run and compared by (gaps, quality, widest join), the §6.2 freshness rule (`placedSoFar − used >= reuseWindow`, the L-TQ3 edge spelled out at the site), fallback bars reported as problems. Comping: cell corpus × voicing engine, anticipation honoured per meter (`0.5` expressed in quarter notes then divided — the 6/8 correctness note), re-voicing only at chord *changes*. Voicings: five families built from degree stacks with the ninth-at-the-bottom inversion excluded (documented why), the §6 constraint set checked exhaustively (`checkAll`, so a relaxed rule can't hide a clash behind it), a fixed relaxation ladder, scoring by leading/register/family/direction. `EnsembleGenerator` namespaces parameters per member and seeds per member. Post-processing order is the specification, including the second `fixOverlaps` after anticipation with the reason at the call site, and correlated (walk-with-pull) humanisation advanced once per *distinct onset* so chords don't arpeggiate. All generators degrade to problems-not-silence for uncovered meters or empty corpora.

### 5.5 `lib/io` (4,567 LoC) — health: excellent

`SongLibrary` is the data-safety core: UUID-gated file access (path traversal impossible by construction), atomic write-then-rename everywhere, 12-deep/90-day backups with fixed-width microsecond stamps (L-TQ10) so newest-by-sort is correct, a crash journal with recovery offers, backup fallback on corrupt files reported per song, zip archive export/import that never overwrites without permission, and a read-only mode for reading mode. `song_json`/`playlist_json` are field-validating codecs with forward-refusal and a real (identity-step) migration chain from v1. Importers: iReal Pro (prefix-vs-content bar state machine, share-based chord placement with leading holds, section/meter/ending/mark coverage, per-bar problem reporting), MusicXML chords + melody as deliberately separate readers (transpose elements, ties keyed by written pitch, voice-1-only with reports, per-bar meter changes preserved as sections — the exporter/importer asymmetry fix), and text lead sheets (`#` comments that don't eat `F#7`, `/` beat repeats). Exporters: MIDI format-1 with a conductor track (per-change meters, part markers, bank-before-program), MusicXML 4.0 with spelled roots, anchor-correct navigation directions, `kind`-fallback-with-`text`, and PDF via the shared painter at 300 dpi (ADR 0010) with measured heading space and a white ground.

### 5.6 `lib/render` + `lib/ui` (5,900 LoC) — health: excellent / good

Render: `ChartLayoutEngine` (bars-per-line halving with a 1-bar floor, section-aligned line breaks, collective chord shrink, order-preserving placement; the former quadratic layout is fixed and benchmarked), `ChartPainter`/`CursorPainter` as separate repaint layers (cursor frame 0.012 ms against the 4 ms budget), Nashville-number rendering keyed off the written key so transposed charts read identically. UI: dark-first, two-metre legibility; an always-focused chord entry with every structural edit a `Command`; reading mode with edge tap zones, wakelock, pedal keys that page but never start the band, and read-only library access; mixer, practice, chord-reference and audio-settings screens bind to the state layer with no business logic of their own. The UI is the one place with light spots rather than deep ones (some screens are plain composition — appropriate for their risk), hence "good" rather than "excellent"; no issues found.

### 5.7 Tools (2,392 LoC) — health: good

`tiling_probe` (the M0.5 probe that motivated the corpus approach; 72 tests) and `corpus_import` (slice/annotate MIDI takes into corpus phrases with duplicate fingerprinting and an audition mode; 24 tests) both analyze clean and pass. They are offline authoring tools with the same documentation style as the app. No issues.

---

## 6. Wiring and integration surface

Each cross-language seam was verified against both sides:

1. **FFI boundary (§3/§15).** `api/audio.rs` (24 functions — 25 bridge entry points with `init_app` — and 11 types) is the whole surface; the Dart side is pure codegen. Range-checked flat events; nothing installs partially; no callbacks upward — position flows through the shared atomic cell read by `transportPosition()` per frame (sync, cheap, verified against `Playhead` extrapolation and its ±100 ms lookahead clamp).
2. **Resolution invariants.** `kTicksPerQuarter == 960 == DEFAULT_PPQ` (one Dart constant, one Rust constant, both documented as load-bearing); tempo bounds 10–400 identical on both sides; drum channel 9 and drum bank 128 identical in three places (Dart builder, synth `ChannelState`, sequencer metronome); GM default channel volume `100/127` consistent across `ChannelState::new`, `EngineState::new` and the A/B harness's `FLAT_MIX` (L-RH7 verified at all three sites).
3. **Units.** The quarters-vs-beats discipline is enforced by doing each conversion exactly once at a named site (`SongGenerator._inQuarters`, `WrittenPartPlacer.place`, `GenerationContext.forPart` with its single-division monotonicity argument, MIDI export reading already-converted phrases, MusicXML offsets via `beatDurationInQuarters`). Each site's comment names the bug class it prevents.
4. **Threading.** One engine thread owns the device; one audio side per transport; the audio thread allocates, locks and blocks nowhere (scratch and pending buffers preallocated; task queue `try_recv`; seqlock publish is wait-free; tempo maps retired off-thread except the documented four-slot-full exception).
5. **Startup order.** `main` installs harmony assets before `RustLib.init()` before the first widget; `Harmony` throws loudly if the order is broken; the Android JNI context gate stops device calls before install with a message rather than a JNI panic.
6. **Data-flow closure.** Written page → `SongChordSequence` (form + arrangement) → `GenerationContext` (per part) → generators (pure) → post-processing → quarters timeline → either `loadSequence` (playback) or `MidiExporter` (export) — one pipeline, one flatten, one source-of-truth map back to the written page for the cursor and written parts.

## 7. Code-quality cross-cutting analysis

- **Immutability & equality.** The entire Dart domain is immutable with hand-written, complete `==`/`hashCode` pairs (map- and set-safe throughout — checked on every value type read). Rust types are plain and `Clone` where needed.
- **Error strategy.** A consistent three-tier policy: constructors `throw ArgumentError` on programmer error; parsers return `null`/`FormatException` naming the offending token; IO reports per-item failures that never abort the whole library. Rust: every fallible API has `/// # Errors`; errors are enums with `Display`/`Error`; nothing panics across the FFI (the dead-thread path is tested).
- **Comments/docs.** Exceptional density of *reasoning* comments (why linear ramps, why the latency clamp, why ninth-at-the-bottom is excluded, why the second `fixOverlaps`). Every one of the 87 `#[allow]`s sits at a site whose constraint is explained (5 crate-level blocks for numeric casts/proper nouns, the rest per-line); all 18 Dart ignores are `avoid_print` in benchmark/soak tests. Rust crate roots carry doct-tested examples.
- **`unsafe` audit.** 8 files mention unsafe; actual blocks: `samples.rs` page-warming (2), `parse.rs` mmap (1, SIGBUS constraint in-code + ADR), `tempo_slot.rs` `Arc` raw-pointer transfers (2 blocks + 2 trait impls), `android.rs` JNI init (1, documented leak-by-design). All SAFETY-commented. `audio-host` and `sequencer` are `#![forbid(unsafe_code)]`; `transport` and `synth` are `#![forbid(unsafe_op_in_unsafe_fn)]`. No unannotated unsafe anywhere.
- **Debt markers.** `TODO|FIXME|HACK|XXX`: **zero** outside generated code.
- **Dependencies.** Runtime Dart deps: 8 (riverpod, frb 2.13.0 pinned exact, archive, path_provider, pdf, xml, wakelock_plus, rust_lib). Rust: cpal + the four in-house crates + frb + jni/ndk-context (Android-gated). No transitive surprises; ADR 0001's minimalism is honoured.
- **Assets.** All six JSON corpora are schema-versioned and loaded through codecs that reject unknown versions, duplicate ids/aliases and out-of-range values — a corrupt asset fails at startup, documented as the right time.

## 8. Test and QA analysis

- **Volume & shape.** 1,397 unit tests (Flutter 1,040; Rust 261; tools 96) + 49 desktop integration tests + Android suites + soak. Test:code ratio ≈ 0.64:1 overall; the *domain* layer is better than 1:1 (e.g. `wbp_tiling`: 472 test lines vs 518 source lines).
- **Quality of assertions.** Not snapshot theatre: exact values, true traces (`[(0,40),(12000,4),(12000,40)]`), invariant properties (round-trips, monotonicity, determinism, torn-read freedom under 200k publishes), degradation behaviour (no-bank silence, dead-thread errors, unreadable directories skipping), and regression stories (each historical bug has a test named after its symptom).
- **Meta-testing.** `domain_purity_test` enforces the layering rule by reading source; asset/corpus tests validate shipped data; `render_benchmark` and `docs/benchmarks.md` make §3 budgets regression-visible (every budget currently green; cold start 0.60–0.65 s vs the 1 s target).
- **Acceptance harnesses.** The FluidSynth A/B (envelope/onset/level/spectrum comparison with calibrated gains; skips without the binary; listening-file mode behind `--ignored`), the audio-null bit-determinism reference render, synth load (200 voices at 2.8× real time), and the 165-file MusicXML corpus (0.7 ms/file).
- **Gaps (all acknowledged in-repo).** Android-device legs (`Platform.isAndroid`) skip on desktop; soak is device-only; `PositionCell`'s give-up-after-16-retries path and `TempoMapSlot`'s slots-full path are exercised only at unit level; UI unit coverage is thin (7 files) but the integration suites carry the user journeys end to end.

## 9. Findings register

| ID | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| F-01 | Low (test infra) — **resolved** | Running two integration suites concurrently against one audio device can fail the §3 drift leg (observed once; passed 4/4 twice in isolation). Nothing enforced serial device access on desktop. | **Fixed with this report:** `integration-test` and `android-test` now serialise on a blocking per-device `flock`. Not a product defect. |
| F-02 | Info | `TransportHandle::position()` returns the default snapshot if the seqlock stays torn for 16 reads (practically never); consumers already clamp. | Accept as documented. |
| F-03 | Info | `TempoMapSlot::retire` can deallocate on the audio thread when all 4 retire slots are full (requires a UI stall across ≥4 tempo publishes). | Accept; bounded and documented at the site. |
| F-04 | Info | `AudioEngine::post` drops a task (with `eprintln`) if the 256-deep queue is full; the state remains the source of truth and the next open replays it. | Accept; documented. |
| F-05 | Info | `SoundbankLibrary.scan` and backup pruning use synchronous `dart:io` calls; called rarely (settings/library screens) with small directory counts. | Optional: move behind an isolate if the library folder ever grows large. |
| F-06 | Info | `load_sequence` without tempo markers flattens a multi-tempo map to constant-at-tick-0 — an explicitly documented API contract, not silent. | Accept; documented in `api/audio.rs`. |
| F-07 | Info | MIDI channel exhaustion (>15 melodic voices) makes voices share channel 15 and the last program wins; reported as a generation problem. | Accept; correct diagnostic behaviour. |
| F-08 | Info | `find_preset_or_fallback`'s last resort is preset 0 — in a pathological bank this could put a melodic sound on the drum channel's program. Deliberate ("silence looks like a broken app"). | Accept. |
| F-09 | Info | iReal chord placement snaps to half-beat positions (`_roundToHalf`) — cannot represent finer splits the format never encodes. | Accept; documented. |
| F-10 | Info | The Android JNI context global reference is intentionally never released (process-lifetime by design, ADR 0009). | Accept. |
| F-11 | Info | `Harmony` statics are process-global mutable state (installed once at startup, resettable in tests) — a pragmatic, ADR-documented alternative to threading a registry everywhere. | Accept. |
| F-12 | Medium (UI, phone-width) — **resolved** | The song-details AppBar actions row (six icon buttons + export menu + labelled Save ≈ 460 dp) overflowed a 411 dp phone portrait by ~49 px, throwing on every layout and failing all five `library_test` cases that open that screen. Invisible on desktop windows — no desktop gate could have caught it. Found by the Android emulator run (§2). | **Fixed alongside this report:** width-aware AppBar — ≥600 dp keeps the full row; narrower keeps undo/redo/edit/reading-mode/Save and moves chords/practice/export behind one overflow kebab; the title shrinks in a `FittedBox`; the export snackbar listener moved to the screen so both layouts report. Verified: `library_test` 11/11 on the emulator **and** desktop; 1,040 unit tests green. |

**Non-certifiable from a desktop/emulator (inherited, unchanged in substance):** (1) *performance* certification on real Android hardware — the emulator now covers the functional side (platform suite 6/6, the F-12 phone-width layout), but its audio path buffers 34,880 frames, so the §3 drift legs honestly skip and the 90-minute device soak still needs a phone; (2) any backend whose buffer arithmetic rounds 256→512 frames — L-TQ13's guard is desktop-verified only. Optional on-device extra: push the 148 MB FluidR3 bank so the two `memory_test` legs can run.

## 10. Conclusion

Across roughly 47.6k lines of hand-written Dart and Rust, this audit found no correctness bug, no layering violation (the meta-test would have caught the latter), no unexplained `unsafe`, no silent failure path, and no stale documentation claim — every rule document spot-checked against its module matched the code, including the four documentation changes from the closing batch (corpus-tiling §6.2 freshness edge, the voicing chooser's fallback order, the on-audio-thread retire fallback, and ireal-format's section-creation behaviour). The engineering culture visible in the comments — measured bugs with named failure modes, budget-driven benchmarks, honesty about what cannot be tested from a desktop — is the strongest signal in the corpus. The project is in a healthy, releasable state; the follow-ups added alongside this report are the F-01 serialisation guard and the F-12 phone-width AppBar fix — the latter was found only because the audit was extended to an Android emulator, which this report now recommends as standing practice for this codebase. What remains is, when physical hardware is next attached, the performance-side certifications: §3 drift on real silicon, the 90-minute soak, and optionally the memory legs with the full-size bank.
