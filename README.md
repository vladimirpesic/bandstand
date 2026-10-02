# Bandstand

Chord charts, backing tracks and practice tools for working musicians.

Flutter for the UI, the song model and all music generation; Rust for the
sampler, the mixer, device I/O and the transport clock. Linux, Windows, macOS,
Android and iPadOS. No web build, no cloud, no accounts.

**Website and downloads:** <https://vladimirpesic.github.io/bandstand/> —
release binaries live on the [releases page][releases].

[releases]: https://github.com/vladimirpesic/bandstand/releases

The full plan — architecture, domain model, milestones, test strategy — is in
[DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Read that first; this file only says
how to build.

## Layout

```plaintext
app/          Flutter application (package: bandstand)
  lib/
    domain/     harmony, song model, commands — no Flutter imports, ever
    io/         file formats, the library on disk, asset loading
    render/     chart layout engine and painters — geometry, not chrome
    state/      Riverpod providers over the domain
    audio/      Dart-side facade over the Rust audio engine
    bridge/     generated FFI bindings — never edited by hand
    ui/         screens, widgets, theme
  test/         unit tests
  integration_test/
rust/         cargo workspace
  bandstand-audio-host/    device enumeration, output streams (cpal)
  bandstand-synth/         parameter ramps, reference tone; sampler at M4
  bandstand-transport/     clock, tempo map, lock-free position readback
  src/                     the FFI surface (published as rust_lib_bandstand)
docs/
  rules/        prose descriptions of every algorithm, written before the code
  decisions/    ADRs
tools/
  tiling_probe/ the M0.5 experiment: does corpus tiling sound musical?
assets/, benchmarks/, renders/ (gitignored)
```

## Building

Toolchain, on Ubuntu:

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libasound2-dev
cargo install flutter_rust_bridge_codegen --version 2.13.0
cargo install just          # optional, but every recipe below assumes it
```

Then:

```bash
just check          # cargo fmt + clippy + test, dart format + analyze + test
just run            # run on the Linux desktop
just build-linux
just build-android
just bridge         # regenerate app/lib/bridge/ after changing rust/src/api/
```

`just integration-test` needs a real audio device and a display; it is the
milestone acceptance harness, not a unit-test runner.

```bash
just probe                 # tile a walking bass line, write renders/tiling-probe.mid
just probe --humanize      # the same line with seeded timing and velocity jitter
just probe --click --tempo 160
```

## Where things are

- **Audio never runs in Dart, UI logic never runs in Rust.** The boundary is
  `rust/src/api/`, and it is deliberately small.
- **Every algorithm has a prose description in `docs/rules/` written before the
  implementation.** That is both a design discipline and the legal discipline of
  §1 of the plan.
- **Every architectural choice has an ADR in `docs/decisions/`.**

## License

Bandstand's code is [Apache-2.0](LICENSE). The recommended soundbank — Frank
Wen's FluidR3 GM, `soundfonts/FluidR3_GM.sf2` — is MIT-licensed, fetched on
demand, and distributed separately from the code (see `soundfonts/README.md`).
