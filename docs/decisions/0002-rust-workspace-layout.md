# ADR 0002 — Rust workspace layout, and why the FFI crate is called `rust_lib_bandstand`

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M0

## Context

§12 puts the cargo workspace at the repo root (`bandstand/rust/`) and §7.1 names
five crates, one of which is `bandstand-ffi`.

`flutter_rust_bridge_codegen integrate` instead scaffolds a single crate at
`app/rust/`, and wires the Flutter native build to it through **cargokit**, the
build driver vendored into `app/rust_builder/cargokit/`. Cargokit:

- reads `<manifest_dir>/Cargo.toml` and requires it to be a **package** manifest,
  not a virtual workspace manifest (`CrateInfo.load` fails without a
  `[package]` section);
- derives the artifact filename from `package.name` — it looks for
  `lib<package.name>.so` / `.a` / `.dll`;
- is told `<manifest_dir>` by five separate build files, one per platform.

The generated app expects `librust_lib_bandstand.so`, and that name appears in
`linux/flutter/generated_plugins.cmake`, the two podspecs, the Android Gradle
plugin config and the Windows CMake file.

## Decision

1. **The workspace moves to the repo root**, as §12 says. The five build files
   were repointed one directory further up:
   - `app/rust_builder/linux/CMakeLists.txt` → `../../../rust`
   - `app/rust_builder/windows/CMakeLists.txt` → `../../../../../../../rust`
   - `app/rust_builder/android/build.gradle` → `manifestDir = "../../../rust"`
   - `app/rust_builder/{ios,macos}/*.podspec` → `../../../rust`
   - `app/flutter_rust_bridge.yaml` → `rust_root: ../rust/`
2. **The `bandstand-ffi` crate of §7.1 is the workspace root package, and it is
   named `rust_lib_bandstand`.** Renaming it to `bandstand-ffi` would rename the
   artifact and break all five build files plus the generated plugin registrant.
   The name is a build-system fact, not a design one; the crate's doc comment
   says so.
3. The other four crates are workspace members in directories named exactly as
   §7.1 has them.
4. `dart_output` is `app/lib/bridge`, matching §12's "`bridge/` generated FFI
   bindings".

## Consequences

- `cargo test` at `rust/` covers the whole audio core with no Flutter involved.
- `flutter build linux` builds the Rust workspace through cargokit unchanged —
  verified at M0.
- The Windows path is seven `..` segments deep and impossible to read. It is
  relative to the plugin symlink directory under `windows/flutter/ephemeral/`,
  not to the repo. If `flutter create` is ever re-run to repair a platform, this
  file is the one to check first.
- `bandstand-sequencer` (§7.1) does not exist yet. It is created at M4, when it
  has something to schedule; an empty crate now would be a placeholder, and §0
  of the plan (§-index: `docs/ARCHITECTURE.md`) asks for working milestones
  rather than scaffolding.
