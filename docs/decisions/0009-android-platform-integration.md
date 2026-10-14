# ADR 0009 — Android platform integration lives in Kotlin, not in Rust

**Status:** accepted · **Date:** 2026-09-04 · **Milestone:** M8

## Context

M8 needs three things from the Android platform: the JNI context that Oboe
requires before it can open a device (`docs/rules/android-audio.md` §1), audio
focus (§2), and a foreground service so playback survives a locked screen (§3).

All three are reachable from Rust through JNI. The `jni` crate can call
`AudioManager.requestAudioFocus`, can build an `AudioAttributes`, and can start
a service. So there is a real choice about where this code lives.

## Decision

**The platform integration is Kotlin. Rust receives one call from it, and
otherwise knows nothing about Android.**

Concretely:

- `NativeAudio.kt` loads `librust_lib_bandstand.so` and hands the application
  context to a single JNI entry point, `initialiseAndroidContext`.
- `AudioFocus.kt` and `PlaybackService.kt` do focus and the service in Kotlin,
  and report to Dart over a method channel.
- Rust gains exactly one Android-only file, and its only job is to store the
  context that Oboe will ask for.

## Why not do it all in Rust

It would work, and it would be worse:

1. **The callbacks are the hard part, and they are Java objects.** Audio focus
   is not a call, it is a listener: `OnAudioFocusChangeListener` is an interface
   Android calls back on the main looper. Implementing a Java interface from
   Rust means either a generated proxy class or `RegisterNatives` against a
   Kotlin shim — so there is Kotlin either way, and the version with a shim is
   the version with two languages and a hand-rolled bridge between them.
2. **Service lifecycle is Android's, not ours.** `startForeground` must be
   called within a few seconds of the service starting or the app is killed,
   notification channels must exist before the notification does, and the rules
   for all of this change by API level. That is a moving target best expressed
   in the language whose documentation describes it.
3. **The audio path stays clean.** `docs/rules/audio-output-path.md` §4 says
   what the audio thread may not do. Threading JNI calls through the crates that
   own the stream puts a JVM attach — which can block, and can allocate — one
   careless refactor away from the callback.
4. **Failure is legible.** A Kotlin exception arrives with a stack trace naming
   Android classes. A JNI misuse from Rust arrives as `SIGSEGV` in `art::`,
   after the fact, on a thread with no symbols.

## Why the *context* still crosses into Rust

Because Oboe asks Rust for it, not Kotlin. `ndk_context` is a global in the
Rust address space, read by cpal on its own threads; nothing in Kotlin can put
something there. One JNI function, storing one global reference, is the smallest
possible surface for that — and it is the only Android-specific Rust in the
project.

## Consequences

- **Two new direct Rust dependencies on Android only**: `jni` and `ndk-context`.
  Neither is new to the build — both already arrive through
  `cpal → oboe → ndk-context` — so this adds no code to the binary that was not
  already in it, only a name to a manifest. They are `[target.'cfg(target_os =
  "android")'.dependencies]`, so no desktop build sees them.
- **The FFI surface does not grow.** §15 asks that adding to the bridge be
  justified; this adds nothing to it. The JNI entry point is called by Kotlin
  and is invisible to Dart.
- **A method channel appears** between Kotlin and Dart, for focus events and
  service control. It is the ordinary Flutter platform channel, not a new
  mechanism.
- **The desktop is unaffected.** Every file added here is either under
  `android/`, or behind `#[cfg(target_os = "android")]`.
- **iOS will need its own version of all of this** (`AVAudioSession`, background
  audio mode) in Swift, by the same reasoning. Nothing here is shared with it,
  and nothing should be.
