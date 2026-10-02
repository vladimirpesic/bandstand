# Bandstand — outstanding audit items

What is left from the three audit reports (`AUDIT_REPORT.md` and the two source
reports it verified), after the confirmed findings were fixed. Those files were
deleted once this list was extracted; they are in git at `8210bc3` if the full
text is ever wanted:

```bash
git show 8210bc3:AUDIT_REPORT.md
git show 8210bc3:BANDSTAND_AUDIT_REPORT_KIMI.md
git show 8210bc3:BANDSTAND_AUDIT_REPORT_GLM.md
```

**Status.** Every finding the audit *confirmed* — 5 high, 16 medium, 30 low — is
fixed and carries a regression test. The items below are the ones the audit
listed but never verified: each has now been checked against the code and
resolved. The real ones are fixed with regression tests, the false premises
were corrected where the claim did not survive re-derivation, and the
sanctioned judgement calls are made and documented beside the code. The
identifiers (`L-I3`, `L-TQ4`, …) are the KIMI report's; the fixes carry them
in comments and test names. Not certifiable from a desktop: an Android-device
run of the platform suite (its `Platform.isAndroid` legs skip here), and the
256→512-rounding backend L-TQ13 guards against, which no local backend
reproduces.

Nothing here is urgent. Several are documentation sync.

---

## 1. Needs a device, or an integration run

Neither could be reached here: `app/integration_test/` needs a device and an
audio target, and the FFI throws until `RustLib.init()` has run.

- [x] **M16 — `platform_audio_test.dart:123-132` is timing-racy.**
  `transportPause()` applies at the next audio block, and `handleFocus` reads
  the transport microseconds later. Depending on where the block boundary falls
  the test fails, or passes vacuously while a still-pending play request applies
  afterwards — leaving playback on into the next test. Poll for the settled
  paused state first; `audio_engine_test.dart:75-88` has the `settledAt`
  pattern. *Plausible from reading; could not be made to fail here.*

- [x] **L-A3 — P1.1/P1.2 shipped without their mandated regression tests.**
  There is no `platform_audio_test` unit seam, so the transient-loss and focus
  logic is verified by reading only. The factual half is confirmed: no seam
  exists. Note that `practice_state.dart` gained a `PracticeTransport` seam
  during this round for exactly this reason — the same shape would work here.

- [x] **L-TQ11 — the drift arithmetic in the comments is wrong.**
  `audio_engine_test` allows 20 ms over 5 s and `synth_test` 2 ms over 10 s;
  against §3's drift rate those are 60× and 3× too loose, and the comments claim
  they are the rate. Tighten to the rate, or reword the comments.

- [x] **L-TQ12 — `generation_test.dart:96-101` asserts `every` on a possibly
  empty iterable**, which is vacuously true. Assert non-emptiness first.

- [x] **L-TQ13 — `synth_test.dart:298-306` fails on a healthy backend** that
  rounds a 256-frame request to 512: both the `bufferFrames` and `blockCount`
  assertions are written against the requested size. Derive the expected block
  count from the negotiated size.

---

## 2. Importers

- [x] **L-I3 — `ireal_import.dart:619-624`.** A `p` at the head of a bar that
  also holds a chord reserves no slot, so the entering chord lands at beat 0 and
  takes the whole bar instead of its second half.

- [x] **L-I4 — `ireal_import.dart:691-697`.** A mid-chart meter change with no
  `*` marker loses the meter; the docs promise a section is created. Downstream
  durations then convert with the old meter.
  *Related work landed this round:* the MusicXML importer now synthesises a
  section on every meter change (see `_startMeterSection`). The iReal importer
  wants the same treatment, and the MusicXML one is the worked example.

- [x] **L-I9 — `musicxml_melody.dart:357`.** An out-of-range written pitch is
  dropped with no problem entry, lumped in with unpitched percussion. Every
  other silent-drop path in the importers reports; this one does not.

---

## 3. Generation and phrase

- [x] **L-S1 — `phrase.dart:71-90`.** `withNote`, `withNotes`, `merged` and
  `onChannel` called on a `SizedPhrase` silently return a plain `Phrase`,
  dropping `beatRange` and its protection. Override the four in `SizedPhrase`.
  Latent — nothing in the repo triggers it.

- [x] **L-B2 — `walking_bass_generator.dart:87-91,163-165`** builds a uniform
  meter grid from `meter.upper`.
  *Mostly closed:* this round established that a song part cannot span a meter
  change (`_expandPart` never leaves its section, and a section carries one
  meter) and asserted that invariant in `song_generator.dart`. The grid is
  therefore correct today. What is left is a judgement call: whether the bass
  generator should carry its own assert, or rely on the one upstream.

- [x] **L-G2 — `voicing_engine.dart:236-246`.** The comment *"no amount of
  smoothness buys one back"* is false beyond roughly seven chords of maximal
  movement: the `movement` term is unbounded and can outscore a relaxation.
  Either compare the relaxation count lexicographically, or document the bound
  the claim actually holds within.

---

## 4. Rust

- [x] **L-RS3 — `riff.rs:159,213`.** A crafted `u32` chunk size can overflow
  `usize` on a 32-bit target. Unreachable on the shipped 64-bit builds. Use
  `checked_add` and compare as `u64`.

- [x] **L-RS4 — `synth.rs:150`.** The recipe buffer pre-sizes to 8
  (`Vec::with_capacity(8)`); a zone match with more than eight layers
  reallocates inside the audio callback. Pre-size around 32, or document the cap
  as a limit rather than a hint.

- [x] **L-RT2 — `sequencer.rs:160-165`.** A program change sitting exactly on
  the loop start is dispatched twice on every pass — once by the seek and once
  by the walk. Idempotent at the synth, and the P1.25 test bakes the current
  behaviour in. Worth making a conscious decision rather than leaving it
  incidental.

- [x] **L-RH4 — `engine.rs:396-416`.** A task posted while `open()` is in flight
  updates `EngineState`, but the new stream replays the older snapshot, so a
  stale mix can persist indefinitely. Re-post the delta after the swap, or
  document the window.

- [x] **L-RH7 — `engine.rs:129`.** The engine's default channel volume is `0.8`
  while the synth's GM-correct default is `100/127` (≈0.787), which is what
  `FLAT_MIX` and the raw-synth paths use. Align them or say why they differ.

---

## 5. Test quality

- [x] **L-TQ4 — `walking_bass_generator_test.dart:271`.** The corpus-load
  benchmark still asserts a *mean* under 100 ms over ten runs. That is the flake
  class P3.26 removed everywhere else; use the `fastestMillis` helper that is
  already in the same file.

- [x] **L-TQ5 — `comping_generator_test.dart:250-271`.** The end-space
  regression test never asserts that the space-less cell actually landed over
  bars 1–2, so a change in cell selection would void the test without failing
  it.

- [x] **L-TQ6 — the `TypeError` half of P2.2 has no test.** The fix landed this
  round (`chord_diagram_library.dart` now catches `TypeError` alongside
  `ArgumentError`, finding M9) but no test pins it. A non-int `baseFret` or a
  non-string `displayName` should surface as a `FormatException`.

- [x] **L-TQ8 — `chart_editor_test.dart:86-94`.** The comment promises that one
  more press "stays put"; the test makes three presses and asserts, never a
  fourth. Add the fourth press and assert the caret has not moved.

- [x] **L-TQ10 — `song_library.dart:599`** (production code, test-adjacent).
  `DateTime.toIso8601String()` omits subseconds when `microsecond == 0`, so
  backup filenames do not sort lexicographically in chronological order within
  one second — and the P3.10 newest-backup assertion relies on that sort. Use a
  fixed-width subsecond format, or sort by mtime.

---

## 6. Documentation sync

Code and docs disagree; in each case the code is right.

- [x] **L-B3 — `docs/rules/corpus-tiling.md` §11** describes the old mean-score
  chooser. The code compares fallback bars first, then quality (mean minus the
  repetition penalty), then the widest join.

- [x] **L-TQ3 — `docs/rules/corpus-tiling.md` §6.2** has stale wording against
  the `>=` freshness rule the code and its test now pin. P2.10's documentation
  half was never done; §4.1 was synced separately.

- [x] **L-RT3 — `docs/rules/transport-clock.md:116-120`** says the audio thread
  never deallocates. `tempo_slot.rs`'s `retire` has a bounded fallback that
  drops the oldest map on the audio thread when all four slots are occupied.
  Amend the documentation.
