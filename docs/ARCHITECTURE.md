# Bandstand — architecture and programme record

> **The 0012 pivot.** Bandstand is now a personal player for the Aebersold
> play-along library; the generative backing band that Bandstand once was is
> retired and its code deleted outright. The scope, the
> feasibility assessment and the keep/remove ledger are in
> [ADR 0012](decisions/0012-personal-aebersold-player.md); the library's
> transport is a MEGA public folder link per
> [ADR 0013](decisions/0013-mega-folder-link.md), ruled by
> `docs/rules/mega-library.md`. **The 0014 rollback.** The beats analysis and
> the MusicXML chart follower that followed the pivot were removed in their
> turn — [ADR 0014](decisions/0014-player-without-charts.md); the player is
> the plain player, and setlists stay. Everything below
> that still describes surviving subsystems — the layering, the boundary
> rules, the audio path, the test strategy — remains in force. Sections and
> rule documents that described removed subsystems are gone; a §N citation
> that resolves to one of them resolves to a retired subject.

This document is the successor to four root-level planning documents, deleted
once their live content had a home in `docs/` — and, with the history reset
that began the repository at the player's 1.0.0, gone outright:

| Deleted document | What it was |
| --- | --- |
| `DEVELOPMENT_PLAN.md` | The build plan: architecture, domain model, milestones, test strategy, working agreement |
| `AUDIT_REPORT.md` | Full-corpus QA audit, 1 October 2026 |
| `REMEDIATION_PLAN.md` | The line-by-line audit's finding catalogue (P0–P3), fully executed |
| `TODO.md` | Audit follow-ups; every item resolved |

The two audit source reports that preceded those were deleted earlier still.
What an auditor needs from all five is condensed into the sections below and
the ADRs in `docs/decisions/`.

## How to read the § citations

The development plan was this codebase's citation hub: rule documents, code
comments, tests and the Justfile refer to its sections as "§N", and still do.
That numbering is kept alive here. **An unqualified "§N" anywhere in this repo
resolves through the index below** — either to the heading of the same number
in this document (§1, §3, §10, §11, §12, §13, §15) or to the living document
that carries the content now; everything else the 0012 pivot removed is
retired, and the history reset at 1.0.0 deleted it outright. The decision
records that described removed subsystems went the same way: ADR 0004, 0007,
0008 and 0010 with the band, ADR 0006 and 0011 with the charts (ADR 0014) —
deleted, not marked obsolete.

| Plan § | Was | Now lives in |
| --- | --- | --- |
| §0 | How to use the plan; scope: local tool, no cloud, no accounts | README; §1 below |
| §0.1 | Progress log, milestone by milestone | §10 below; the per-milestone build journals are gone |
| §1 | Legal ground rules | §1 below |
| §2 | Feasibility verification; non-goals | non-goals below; the measurements are gone |
| §3 | Architecture, boundary rules, performance budgets | §3 below, verbatim |
| §4.1 | Pitch and harmony | retired — the harmony domain (ADR 0014) |
| §4.2 | Time and phrases | retired — the generative band (ADR 0012) |
| §4.3 | Song structure | retired — the song model (ADR 0014) |
| §4.4 | Undo/redo, command pattern | retired — the song model (ADR 0014) |
| §4.5 | Form navigation: repeats, endings, D.S., coda | retired — the song model (ADR 0014) |
| §4.6 | Meter scope — never offer a meter you have no vocabulary for | retired — the generative band (ADR 0012) |
| §5.1 | Native song format | retired — the song model (ADR 0014) |
| §5.2 | Importers and their priority | retired — the importers (ADR 0014) |
| §5.3 | Exporters | retired — the exporter (ADR 0014) |
| §5.4 | Data safety | `docs/rules/mega-library.md` (the cache's files and flags) |
| §6.1 | Generation pipeline | retired — the generative band (ADR 0012) |
| §6.2 | Generator interface, explicit seed | retired — the generative band (ADR 0012) |
| §6.3 | Corpus tiling — the key architectural finding | retired — the generative band (ADR 0012) |
| §6.4 | Building your own corpus | retired — the generative band (ADR 0012) |
| §6.5 | Generators in order | retired — the generative band (ADR 0012) |
| §6.6 | Arrangement-level features: density arc, fills, anticipation, humanisation | retired — the generative band (ADR 0012) |
| §7.1 | Rust crate layout | `rust/Cargo.toml`; README "Layout" |
| §7.2 | Synth requirements: polyphony cap, streaming, reverb | retired — the SF2 sampler (ADR 0012) |
| §7.3 | Transport, and loops | `docs/rules/transport-clock.md` |
| §7.4–7.5 | Platform backends; MIDI I/O | `docs/rules/android-audio.md`, `docs/rules/audio-output-path.md` |
| §8.1 | Chart renderer constraints | retired — the chart renderer (ADR 0014) |
| §8.2 | Screens | the app; §10 below |
| §8.3 | State management | ADR 0003 |
| §9 | iReal Pro feature analysis: what to build, skip, do differently | retired — the importers (ADR 0014); the analysis is gone |
| §10 | Milestones and acceptance criteria | §10 below |
| §11 | Test strategy: 11.1 oracle, 11.2 layers, 11.3 benchmarks | §11 below |
| §12 | Repository layout; development environment | README "Layout" / "Building"; §12 below |
| §13 | Risk register | §13 below |
| §14 | Reference index: the read-only JJazzLab and vree trees | retired — the trees were machine-local and never entered the repo |
| §15 | Working agreement for the coding agent | §15 below |

**§2's non-goals, kept because they are what keeps the project finishable:**
not a DAW (no multitrack recording, waveform editing or plugin hosting); not a
notation editor; no cloud, accounts, sync or sharing; no
web build; no automatic transcription or score alignment — the chart follower
was built, proved unusable, and removed (ADR 0014); alignment of any kind is
explicitly not promised.

## 1. Legal ground rules

Bandstand is a personal app for one user and is never distributed — that is
what retired the old analysis (ADR 0004, deleted with the JJazzLab
reference work it governed). What stays is the discipline every `docs/rules/`
file's "Written per §1 / §15" line enforces, and the one exposure that
remains:

- The safe discipline for any outside reference: read it to understand an
  algorithm, **write the rule down in prose, implement from your own prose.**
  A line-by-line translation is a derivative work; changing language does not
  launder a licence.
- The Aebersold recordings and book PDFs the library mirrors are copyrighted
  material for the owner's personal use. They stay on his devices: no
  re-sharing, no re-upload, no "backup" that is really a distribution.
- Bandstand's own code is Apache-2.0; every third-party licence rides along
  in `Cargo.lock` and `pubspec.lock`, both committed.

## 3. Architecture and performance budgets

Flutter/Dart owns the person's side — the library mirror, the settings, the
player screen and its state, the PDF reader over the same cache, search
across the whole manifest — and Rust
owns real-time audio: devices, the decoder, the channel-gain matrix, the
transport. UI and library state are
allocation-heavy, constantly rewritten, and want stateful hot reload: Dart.
Audio is a real-time thread where a GC pause is an audible glitch: Rust.
`flutter_rust_bridge` is the boundary, so the playhead is a shared atomic
rather than IPC (ADR 0002).

**Boundary rules:** never audio logic in Dart; never UI logic in Rust;
`app/lib/bridge/` is generated and never edited by hand. But *policy* is
Dart's, executed over the bridge: the
Android focus handshake (ADR 0009) is the only way playback starts, and the
end-of-track stop is the caller's decision — the engine reads silence past
the last decoded frame by design, so the player can watch the playhead pass
the duration, stop and give focus back rather than have the transport
second-guess the app.

Design against these budgets where the surviving audio path still meets them
(the generative-era budgets — regeneration, chart repaint, sample-bank
memory — left with the band, and their measurement history with them; the
benchmark suite itself is §11.3):

| Metric | Target | Hard limit |
| --- | --- | --- |
| Audio output latency, desktop | 10 ms | 25 ms |
| Audio output latency, Android | 25 ms | 60 ms |
| Dropouts during a 90-minute set | 0 | 0 |
| Cursor drift over 5 minutes | 10 ms | 20 ms |
| Cold start to library visible | 1 s | 3 s |

## 10. Milestones and acceptance

A milestone was done only when its acceptance test had actually been run and
passed — not when the code existed. Status at the plan's retirement — the
generative product as first released; the per-milestone build journals are gone:

| Milestone | Acceptance criterion | Status |
| --- | --- | --- |
| M0 skeleton | a sine through a real device, zero dropouts, drift inside §3 | ✅ Linux and Android |
| M0.5 probe | does corpus tiling sound musical at all? | paradigm accepted; the quality was M6's to build |
| M1 harmony | parser, transposition and round-trip suites, asserted by count | ✅ |
| M2 song model | 100 songs, 50 undos without divergence, playlist overrides do not mutate the song | ✅ |
| M3 renderer/editor | 50 iReal charts imported and laid out; readable at 2 m; edit a 32-bar tune in under 2 minutes | built; the two human judgements stand |
| M4 synth/transport | play General MIDI; A/B against FluidSynth; drift under 20 ms over 5 minutes; no dropouts at a 256-frame buffer for an hour | ✅ (A/B: identical onsets, 0.997 envelope correlation, +0.8 dB) |
| M5 drums/mixer | press play on a chart and hear time; regeneration after a chord edit under 200 ms | ✅ (measured ~1 ms) |
| M6 walking bass | a blind listening test; a line that "does not repeat audibly over 3 choruses" | built and measured; the listening test is the human's |
| M7 comping/voicings/practice | voicing suite: no root doubling, "voice movement under 4 semitones", no interval clashes; tempo ramp exact over a 20-minute session | ✅ |
| M8 mobile hardening | "a 90-minute set on the tablet, screen locked and unlocked repeatedly", no audio interruption, battery drain acceptable | all but battery drain — needs a real device |
| M9 export and extras | MIDI/audio/PDF/MusicXML export; importers complete | exporters, importers, the benchmark suite and the audio null test built; optional extras open |

## 11. Test strategy

- **Layers** (§11.2): unit tests per layer — the manifest, cache and
  setlist codecs round-trip and fail naming fields, the player runs behind
  seam fakes, the MEGA client asserts against a local fake server speaking
  the real protocol with real bytes; integration suites run on a real audio
  device. (The harmony-domain and golden-renderer suites, and the audio null
  tests against stored references in `rust/tests/`, left with the band and
  then the charts — ADRs 0012 and 0014.)
- **Benchmarks** (§11.3): the generative-era suite — `benchmarks/run.sh`
  (`just bench "heading"`), measuring every §3 budget together and appending
  a dated section to `docs/benchmarks.md`, so regressions were visible across
  months rather than discovered on stage — left with the band (ADR 0012).
  Building it found the chart layout was quadratic in
  bar count. Timing budgets assert on release builds only; a debug build
  measures the optimiser, not the code.
- **Integration suites must run serially per audio device** — the drift
  measurement includes real device scheduling. Enforced with a blocking
  per-device `flock` in the Justfile (audit F-01).

## 12. Development environment

Ubuntu toolchain and build recipes: README, "Building". The pins that matter:
`flutter_rust_bridge_codegen` **2.13.0**; `apt install clang cmake ninja-build
pkg-config libgtk-3-dev liblzma-dev libasound2-dev`; `just` for every recipe.

GitHub Actions builds the release binaries with the same recipes
(`.github/workflows/release.yml`), and a `v*` tag publishes them as a GitHub
Release; the workflow needs no MEGA access, because the folder link is a
runtime setting of the app rather than a build input (ADR 0013).

## 13. Risk register

| Risk | Standing mitigation |
| --- | --- |
| The MEGA folder link dies, throttles or moves | the manifest and the local mirror keep the app working offline; re-pointing is one settings field; the cache is never auto-purged (ADR 0013, `docs/rules/mega-library.md`) |
| OEM Android audio paths drift or round buffers | the §3 drift budgets, `just android-check`'s page-alignment gate, and the emulator QA pass of the pre-reset audit — its recipes went with the release workflows |
| Copyrighted material leaking | personal use only — recordings and book PDFs stay on the owner's devices (§1) |
| Scope creep back into a band-in-a-box | the pivot's keep/remove ledger is the boundary (ADR 0012); the follower arc's ledger is the other one (ADR 0014) |

## 15. Working agreement for the coding agent

- Read `docs/decisions/` before proposing architecture changes; add an ADR
  when making one.
- Audio code has no UI concepts. UI code touches audio only through the
  bridge.
- No new dependency without an ADR justifying it (ADR 0001). The point of
  this project is owning the stack.
- Every algorithm gets a prose description in `docs/rules/` before
  implementation.
- Every bug fix gets a regression test first.
- Prefer data over code where the thing is data: the manifest, the cache
  flags and setlists are files, not structures in code.
- Keep the FFI surface small. Adding a function to the bridge requires
  justification.
- When stuck on musical judgement, stop and ask the human. Aesthetic
  decisions are not the agent's to make.

## Audit trail

Four audit artefacts sat at the repo root; all are resolved, and their finding
IDs still appear in code comments and test names, so the legend stays:

- **`REMEDIATION_PLAN.md`** — the line-by-line audit of the hand-written Dart
  and Rust corpus. Findings numbered `P0.1`–`P3.x` by priority: **P0**
  user-facing damage, **P1** real bugs in reachable paths, **P2** edge cases
  and hygiene, **P3** test quality. Every confirmed finding was fixed with a
  regression test.
- **`L-*` IDs** (from the audit's source reports, since deleted) — `L-RH*`
  engine, `L-RS*` synth, `L-RT*` transport/sequencer, `L-I*` importers,
  `L-S*` song/phrase, `L-B*` bass, `L-A*` audio state, `L-G*` generation,
  `L-TQ*` test quality. All fixed with regression tests; the fixes carry the
  IDs in comments and test names, and the sanctioned judgement calls are
  documented beside the code they govern.
- **`AUDIT_REPORT.md`** (1 October 2026) — every
  hand-written file read in full (~48k lines of Dart and Rust; 65,777 lines
  of corpus with Markdown, JSON and tests), every QA gate re-run from
  scratch: 261 Rust tests, 1,040 Dart unit tests, 49 desktop integration
  tests across nine suites, plus an Android emulator pass. **Verdict:
  excellent — ship quality.** No correctness defect anywhere; no layering
  violation (the meta-test would have caught it); no unexplained `unsafe`; no
  silent failure path; no stale documentation claim. The findings register
  `F-01`–`F-12` held zero blocking or high items: **F-01** (two integration
  suites contending for one audio device can fail the drift leg — fixed with
  the per-device `flock`) and **F-12** (the song-details AppBar overflowed a
  411 dp phone portrait — fixed with a width-aware AppBar) were fixed
  alongside the report; **F-02…F-11** were accepted as documented behaviour
  (torn-read clamp after 16 seqlock retries, the bounded on-thread retire
  fallback, task-queue overflow dropping with replay on next open,
  synchronous scans on rarely-visited screens, the tempo-map flattening
  contract, channel-exhaustion diagnostics, the preset-0 last resort, iReal
  half-beat snapping, the process-lifetime JNI reference per ADR 0009, and
  the `Harmony` statics).
- **`TODO.md`** — the items the audits listed but had not verified: each was
  checked against the code and resolved — the real ones fixed with regression
  tests, the false premises corrected where a claim did not survive
  re-derivation.

**Not certifiable from a desktop or an emulator** — the standing list for
whoever next attaches physical hardware:

1. §3 drift and latency on real Android silicon. The emulator's audio path
   buffers 34,880 frames, so the drift legs honestly refuse to run there.
2. The 90-minute device soak (its recipe went with the release workflows).
   The emulator's 90-minute
   set passed — zero dropouts across 404 screen locks and 134 unlocks — but
   battery drain needs a phone.
3. Any audio backend that rounds a 256-frame request to 512 frames; L-TQ13's
   guard is desktop-verified only, because no local backend reproduces the
   rounding.

**Standing practice adopted from the audit:** when Android behaviour is in
question, rerun the emulator QA pass of that audit — a 411 dp portrait phone,
16 KB pages; its recipe went with the release workflows. It is
the only thing that caught F-12, which no desktop gate could have seen.
