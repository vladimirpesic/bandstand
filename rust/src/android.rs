//! The one piece of Android-specific Rust in the project (ADR 0009).
//!
//! Oboe — cpal's Android backend — reaches the platform through JNI, and finds
//! its way there by asking [`ndk_context`] for a `JavaVM` and an
//! `android.content.Context`. On a plain Rust Android app a runtime such as
//! `ndk-glue` puts them there before `main`. Bandstand has no such runtime: its
//! Rust is a `cdylib` loaded by the Dart FFI, and nothing in that path knows
//! about Android. So without this file, the first call that opens an audio
//! device panics with *"android context was not initialized"*, which is exactly
//! what the M0 acceptance leg hit.
//!
//! Rules: `docs/rules/android-audio.md` §1.

use std::sync::atomic::{AtomicBool, Ordering};

use jni::objects::{JClass, JObject};
use jni::JNIEnv;

/// Whether a call has claimed the right to install the context.
///
/// [`ndk_context::initialize_android_context`] asserts it has not been called
/// before, so a second call is a panic rather than a no-op — and Kotlin *will*
/// call twice, because `MainActivity.onCreate` runs again after a configuration
/// change. Guarding here rather than in Kotlin keeps the invariant next to the
/// thing it protects.
static CLAIMED: AtomicBool = AtomicBool::new(false);

/// Whether the context is actually installed and usable.
///
/// Separate from [`CLAIMED`] because the two are true at different moments.
/// [`is_initialised`] gates `audio_start`, and a single flag set at the top of
/// the install meant a start racing the install passed the gate and then
/// panicked inside JNI against a context that was not there yet. This one is
/// set last, after the context is in place.
static INITIALISED: AtomicBool = AtomicBool::new(false);

/// Install the Android context, so the audio backend can open a device.
///
/// Called once from Kotlin, with the **application** context — not an
/// activity's. An activity is destroyed and recreated on rotation, and Oboe
/// holds this for the life of the process.
///
/// Returns `true` when this call installed the context and `false` when it was
/// already there, so Kotlin can log the difference rather than guess.
///
/// # Safety
///
/// Called by the JVM through JNI with a valid environment and a valid context
/// object. The reference is promoted to a global one before it is stored,
/// because a local reference dies with the call that received it and Oboe will
/// use this from its own threads, later.
#[no_mangle]
pub extern "system" fn Java_dev_bandstand_NativeAudio_initialiseAndroidContext(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    context: JObject<'_>,
) -> bool {
    // `compare_exchange` rather than a load-then-store: two threads racing here
    // would both see `false` and both call through, and the second would
    // assert.
    if CLAIMED
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return false;
    }

    let Ok(vm) = env.get_java_vm() else {
        CLAIMED.store(false, Ordering::SeqCst);
        return false;
    };
    let Ok(global) = env.new_global_ref(context) else {
        CLAIMED.store(false, Ordering::SeqCst);
        return false;
    };

    // SAFETY: `vm` is the JavaVM this thread is attached to, and `global` is a
    // global reference that outlives the call. The context is deliberately
    // never released: the process outlives every activity, and dropping it
    // while an audio thread held it would be worse than leaking one reference
    // (`docs/rules/android-audio.md` §1).
    unsafe {
        ndk_context::initialize_android_context(
            vm.get_java_vm_pointer().cast(),
            global.as_raw().cast(),
        );
    }
    std::mem::forget(global);
    // Last, so that anything gated on `is_initialised` only sees `true` once
    // the context really is installed.
    INITIALISED.store(true, Ordering::SeqCst);
    true
}

/// Whether the Android context has been installed.
///
/// Read by [`crate::api::audio`] so that a missing context is reported as a
/// message rather than as a panic across the FFI boundary.
#[must_use]
pub fn is_initialised() -> bool {
    INITIALISED.load(Ordering::SeqCst)
}
