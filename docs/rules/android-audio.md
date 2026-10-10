# Android audio

Written per §1 / §15, for M8: *"Android audio focus + foreground service"*, and
for the M0 acceptance leg deferred to it.

The desktop audio path is `docs/rules/audio-output-path.md` and none of it
changes here. What changes is everything *around* the stream: on a desktop a
process that opens an output device keeps it until it closes it, and on Android
it does not. The system can take the device away, the process can be killed for
being in the background, and neither is an error condition — they are the
platform working as designed. This document is how Bandstand cooperates.

## 1. The JNI context, and why the audio engine panics without it

cpal's Android backend is Oboe, and Oboe reaches the platform through JNI. It
gets there via `ndk_context::android_context()`, which returns a `JavaVM` and an
`android.content.Context`, and which **panics** — `"android context was not
initialized"` — if nobody has supplied them.

On a plain Rust Android app the runtime (`ndk-glue`, `android-activity`) does
that before `main`. Bandstand has no such runtime: it is a Flutter app whose
Rust is a plain `cdylib` loaded by the Dart FFI, and nothing in that path knows
about Android at all. So the app must do it itself, and until it did, opening a
device on Android panicked on the first call. That is why the M0 acceptance leg
could not pass and was deferred here.

**The rule: the context is installed from Kotlin, once, before any audio call.**

- Kotlin loads the library and hands the **application** context down, not the
  activity's. An activity is destroyed and recreated on rotation and on
  configuration changes; a pointer to one is a use-after-free waiting for a
  landscape phone. The application context lives as long as the process, which
  is exactly as long as the audio engine does.
- Rust promotes it to a **global JNI reference**. A local reference is valid
  only for the duration of the native call that received it, and Oboe will use
  this one from its own threads, later.
- Initialisation is **idempotent**. `ndk_context::initialize_android_context`
  asserts it has not been called before, so calling it twice is a panic rather
  than a no-op — and Kotlin *will* call twice, because `MainActivity.onCreate`
  runs again after a configuration change. Rust guards it, rather than asking
  Kotlin to remember.
- It is never released. `release_android_context` exists for a runtime that owns
  the activity lifecycle; here the process outlives every activity, and dropping
  the context while an audio thread holds it would be worse than leaking one
  global reference for the life of the process.

## 2. Audio focus

Android arbitrates who plays. A phone call, an alarm, a navigation prompt or
another music app all take focus, and an app that ignores that plays over the
top of them.

Bandstand requests focus when the transport starts and abandons it when the
transport stops. What it does when focus is *lost* depends on how it was lost:

| Loss | What a backing band should do |
| --- | --- |
| **Permanent** — another app took over | **Stop.** Not pause: the user has left. |
| **Transient** — a call, an alarm | **Pause**, and resume when focus returns. |
| **Transient, may duck** — a navigation prompt | **Duck**, and restore the level after. |

Two details that matter on stage:

- **Resume is only automatic after a transient loss that Bandstand caused a
  pause for.** If the user paused before the interruption, focus returning must
  not start the band playing at them.
- **Ducking is a gain change, not a pause.** The transport keeps running, so the
  cursor stays where the player is looking. Restoring the level exactly is why
  the ducked-from gain is remembered rather than assumed.

Focus is requested with `AudioAttributes` of usage `MEDIA` and content type
`MUSIC`, which is what a backing track is, and what tells the system to duck
navigation rather than interrupt it.

## 3. The foreground service

§10's acceptance is *"a 90-minute set on the tablet, screen locked and unlocked
repeatedly, no audio interruption"*. A backgrounded Android app is killable at
any moment, and a locked screen backgrounds it. Without a foreground service the
band stops somewhere in the second tune and the acceptance is unmeetable.

So: **the transport running is what starts the service, and the transport
stopping is what stops it.** Not the app being open, not the screen being on.

- The service is typed `mediaPlayback`, which is what it is, and which is the
  type Android requires for audio that continues in the background.
- Its notification is not decoration. Android will not allow the service without
  one, and it is also how a player who has locked the tablet stops the band
  without unlocking it.
- The service **does not own the audio**. The Rust engine already owns the
  stream and the transport; the service exists to tell Android this process is
  doing something the user asked for. Making it own playback would put the audio
  path behind a binder interface for no gain.

## 4. Permissions

Three, and no more:

- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MEDIA_PLAYBACK` — the service of
  §3. The typed one is required from Android 14.
- `POST_NOTIFICATIONS` — required from Android 13 for the service's own
  notification to be seen. Playback still works if it is refused; the
  notification is simply silent, so the app asks and does not insist.
- `WAKE_LOCK` — a partial wake lock while the transport runs, so a sleeping CPU
  does not stop the band. The screen is not held on by this; reading mode does
  that separately, and only while it is on screen.

Bandstand asks for no network, no storage and no microphone permission. It has
no use for them, and §0's scope rule is that this is a local tool.

## 5. 16 KB page sizes

Android 15 introduced devices with 16 KB memory pages, and from API 35 a native
library that is not aligned for them will not load. The emulator this was
developed against is one of them — `sdk_gphone16k_x86_64`.

The requirement is **64-bit only**. A 16 KB device does not run 32-bit code at
all, so `arm64-v8a` and `x86_64` must be aligned and `armeabi-v7a` need not be;
it ships at 4 KB and that is correct rather than a fault.

This is a build-configuration property rather than a code one, and it is
verified rather than assumed: `just android-check` reads the alignment out of
the packaged libraries and fails if a 64-bit one is under 16 KB.

## 6. What this deliberately does not do

- **MediaSession, lock-screen transport controls, Bluetooth media buttons.**
  Worth having, and §9 puts page-turner input at M8 — but a media button is a
  different input path from a foot pedal and neither is audio hardening.
- **Bluetooth audio routing choices.** The system routes; Bandstand plays.
- **Battery optimisation exemptions.** Asking a user to exempt an app from
  battery management is a thing to do only if the foreground service turns out
  not to be enough, and it is not the first move.

## 7. The soak, and what it can prove without a tablet

§10's acceptance for M8 is *"a 90-minute set on the tablet, screen locked and
unlocked repeatedly, no audio interruption, battery drain acceptable"*. It has
four parts and they are not equally hardware-bound:

| Part | Where it can be taken |
| --- | --- |
| 90 minutes of continuous playback | anywhere the app runs |
| Screen locked and unlocked repeatedly | an emulator: `adb shell input keyevent 26` is the power button |
| No audio interruption | an emulator, for the **mechanism** — whether the process survives, the stream keeps its callbacks and the dropout counter stays at zero |
| Battery drain acceptable | **a real device only** |

So three of the four are testable without a tablet, and the fourth is not
testable at all without one. `integration_test/soak_test.dart` takes the three.

**Locking the screen is the whole point of the exercise.** A backgrounded
Android app is killable at any moment, and that is what §3's foreground service
exists to prevent. So the soak does not idle for ninety minutes: it cycles the
screen every twenty seconds, because thirty lock/unlock transitions prove far
more about the service than five thousand seconds of nothing happening. The
duration is a parameter, and the default is short enough to run in a change
loop.

What the soak asserts at every step:

1. The transport is still playing.
2. The playhead has **advanced** since the previous check — a stream whose
   callbacks stopped publishes a frozen tick, which is what a killed service
   looks like from Dart.
3. The backend's dropout counter is still zero.
4. The block counter has risen, so callbacks are still arriving.

A failure names the cycle it happened on and whether the screen was on or off
at the time, because "it dies on the third lock" and "it dies after ten minutes"
are different faults.
