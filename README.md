# Bandstand

A personal practice app for the Jamey Aebersold play-along library: browse it
over a public MEGA folder link (ADR 0013), cache tracks and books locally,
play them with channel isolation (bass side / piano side), read the books,
and — in time — follow sheet music synced to the recordings.

Flutter for the UI and the library model; Rust for the audio engine, the
transport clock and device I/O. Linux desktop and Android. No web build, no
cloud of our own, no accounts at all.

> **Where this repo is:** the backing-band generator that Bandstand was first
> released as (chord charts, walking-bass/comping/drum generation, SF2
> sampler) has been retired, and the history reset at this 1.0.0 deleted it
> outright. The pivot, the feasibility assessment behind it and the roadmap
> are in [ADR 0012](docs/decisions/0012-personal-aebersold-player.md).

The architecture record — layering, performance budgets, test strategy, audit
trail — is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and every
algorithm has a rule document under `docs/rules/`. This file only says how to
build.

## Layout

```plaintext
app/          Flutter application (package: bandstand)
  lib/
    domain/     harmony, song model, commands — no Flutter imports, ever
    io/         file formats, the library on disk, asset loading, importers
    render/     chart layout engine and painters — geometry, not chrome
    state/      Riverpod providers over the domain
    audio/      Dart-side facade over the Rust audio engine
    bridge/     generated FFI bindings — never edited by hand
    ui/         screens, widgets, theme
  test/         unit tests
  integration_test/
rust/         cargo workspace
  bandstand-audio-host/    device enumeration, output streams (cpal/Oboe)
  bandstand-transport/     clock, tempo map, loop regions, position readback
  src/                     the FFI surface (published as rust_lib_bandstand)
docs/
  rules/        prose descriptions of every algorithm, written before the code
  decisions/    ADRs — 0012 is the pivot to the Aebersold player
tool/          brand/icon generation
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
acceptance harness, not a unit-test runner.

GitHub Actions builds both release binaries on every push to `main`
([`.github/workflows/release.yml`](.github/workflows/release.yml)) and uploads
them to the workflow run page; a pushed `v*` tag publishes them as a GitHub
Release. Nothing in the build touches the MEGA folder — the link is a runtime
setting of the app (ADR 0013) — so the workflow needs no secrets.

## Where things are

- **Audio never runs in Dart, UI logic never runs in Rust.** The boundary is
  `rust/src/api/`, and it is deliberately small.
- **Every algorithm has a prose description in `docs/rules/` written before the
  implementation.** That is both a design discipline and the legal discipline of
  §1 of `docs/ARCHITECTURE.md`.
- **Every architectural choice has an ADR in `docs/decisions/`.**
- **A bare "§N" citation, in code or docs, resolves through the plan-section
  index in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — the numbering of
  the original development plan, kept as the citation scheme.

## License

Bandstand's code is [Apache-2.0](LICENSE).
