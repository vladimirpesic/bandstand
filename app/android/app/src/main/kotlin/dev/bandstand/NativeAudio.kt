package dev.bandstand

import android.content.Context

/**
 * Hands the Android context to the Rust audio engine.
 *
 * Oboe — the backend cpal uses on Android — reaches the platform through JNI
 * and asks `ndk_context` for a `JavaVM` and a `Context`. On a plain Rust
 * Android app a runtime supplies those before `main`; a Flutter app has no such
 * runtime, so without this the first call that opens a device panics with
 * "android context was not initialized".
 *
 * See `docs/rules/android-audio.md` §1 and ADR 0009.
 */
object NativeAudio {
    private var loaded = false

    /**
     * Install the context, once.
     *
     * Pass the **application** context, never an activity's: an activity is
     * destroyed and recreated on rotation, and the audio engine holds this for
     * the life of the process.
     *
     * Safe to call repeatedly — `MainActivity.onCreate` runs again after a
     * configuration change, and the Rust side treats the second call as a
     * no-op.
     *
     * @return true when this call installed the context, false when it was
     *   already there or the library could not be loaded.
     */
    fun install(context: Context): Boolean {
        if (!loaded) {
            try {
                System.loadLibrary("rust_lib_bandstand")
                loaded = true
            } catch (error: UnsatisfiedLinkError) {
                // Nothing here can recover from a missing native library, and
                // throwing would take the app down before it could say so. The
                // audio screen reports the engine as unavailable instead.
                return false
            }
        }
        return initialiseAndroidContext(context.applicationContext)
    }

    private external fun initialiseAndroidContext(context: Context): Boolean
}
