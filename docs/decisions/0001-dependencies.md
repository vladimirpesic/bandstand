# ADR 0001 — The dependency set, and the rule for adding to it

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M0

## Context

§15 of the plan: *"No new dependency without an ADR justifying it. The point of
this project is owning the stack."* This ADR records the dependencies M0
introduces and the test any future one has to pass.

## Decision

### The test for a new dependency

A dependency is justified only when **all** of the following hold:

1. It sits at a platform boundary we do not want to own (device I/O, the FFI
   bridge, the Flutter framework itself), **or** it is a well-specified,
   finished problem with no musical judgement in it.
2. Owning it would cost weeks and buy nothing the product is about.
3. It does not reach into the domain layer. Nothing in `app/lib/domain/` may
   import anything outside `dart:` and the domain itself.
4. Its licence permits the distribution model of §1.

Explicitly **failing** the test, and therefore written by hand: chord parsing,
music theory, chart layout, the song file format, MIDI file reading and writing,
the sampler, and every generator. These are the product.

### Rust

| Crate | Why |
| --- | --- |
| `cpal` | The platform audio boundary (§7.4): ALSA/PipeWire, WASAPI, CoreAudio, Oboe behind one API. Owning five backends is a project in itself and buys nothing musical. Apache-2.0. |
| `flutter_rust_bridge` | The FFI boundary itself; mandated by §3. MIT. |

Nothing else. `bandstand-transport` and `bandstand-synth` depend on `std` alone,
which is what lets them be tested exhaustively and reasoned about on the audio
thread.

### Dart

| Package | Why |
| --- | --- |
| `flutter_riverpod` | State management, mandated as a choice by §8.3 — see ADR 0003. |
| `path_provider` | The platform boundary for "where may this app write" (M2, §5.1). Every platform answers differently and Android answers differently by API level; owning that is five platform channels and no music. Flutter-team package. |
| `archive` | Zip, for the whole-library export of §5.4. A finished, specified problem with no musical judgement in it. Pure Dart, so it runs in tests without a device. |
| `flutter_lints` | Lint baseline. |
| `integration_test`, `flutter_test` | Test harness. |

Deliberately **not** taken, and written by hand instead:

- **UUIDs** — `lib/io/uuid.dart` is twenty lines of `Random.secure`. A dependency
  for that fails test 2.
- **JSON serialization** (`json_serializable`, `freezed`) — §5.1 asks for a
  format with no reflection and no framework, so that adding a field is a
  deliberate act with a migration attached. Codecs are written by name in
  `lib/io/song_json.dart`.

## Consequences

- The audio thread's dependency surface is `cpal` plus `std`, which is small
  enough to audit for allocation and locking.
- Any future PR adding a dependency must add an ADR here first.
