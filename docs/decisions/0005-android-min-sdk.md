# ADR 0005 — Android minimum SDK is 26

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M0

## Context

The `flutter create` scaffold set the application's `minSdk` from
`flutter.minSdkVersion`, and cargokit's own Android plugin declared
`minSdkVersion 19`. Building the Rust library for `armv7-linux-androideabi`
failed at link time:

```bash
ld.lld: error: unable to find library -laaudio
```

**AAudio arrives at API 26.** The NDK ships `libaaudio.so` stubs only in
platform directories from 26 upwards, so a build targeting a lower API cannot
link against it. cpal's Android backend is Oboe, and Oboe links AAudio.

Oboe does fall back to OpenSL ES at runtime on older devices, but that is a
*runtime* fallback inside a library that still links AAudio at build time. There
is no configuration that produces an API-19 binary with Oboe's AAudio path
available.

## Decision

**`minSdk = 26` (Android 8.0, 2017), in both `app/android/app/build.gradle.kts`
and `app/rust_builder/android/build.gradle`.** The two must stay equal —
cargokit passes its own value to the NDK toolchain, and a mismatch reproduces
this error with a much more confusing message.

## Why this is the right trade, not just the convenient one

- The §3 budget is 25 ms output latency on Android. That is an AAudio number.
  On OpenSL ES, with the buffer sizes Android grants, it is not reliably
  achievable. Shipping a build that cannot meet its own latency budget on
  devices we claim to support would be worse than not supporting them.
- Android 8.0 is nine years old. The target user is someone putting a tablet on
  a music stand; that device runs something far newer.
- Every Android audio feature the plan schedules for M8 — audio focus changes,
  the foreground service type, `AudioAttributes` usage hints — has a cleaner API
  above 26.

## Consequences

- Devices below Android 8.0 are not supported. Recorded here so it is a decision
  rather than an accident discovered on a store listing.
- If OpenSL-era devices ever matter, the change is a separate audio backend, not
  a gradle flag.
