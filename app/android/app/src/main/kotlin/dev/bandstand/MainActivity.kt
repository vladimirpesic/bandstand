package dev.bandstand

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Android host, and the only place platform integration is wired up.
 *
 * Three jobs: install the JNI context the audio backend needs (§1), keep
 * audio focus (§2), and run a foreground service while the transport is
 * going (§3) — all from `docs/rules/android-audio.md`.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var focus: AudioFocus? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Before anything can open a device. Idempotent on the Rust side,
        // because this runs again after a configuration change.
        val installed = NativeAudio.install(applicationContext)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val platform = MethodChannel(messenger, CHANNEL)
        channel = platform

        focus = AudioFocus(applicationContext) { event ->
            // Straight to Dart, which owns the decision about what to do: the
            // policy is in `docs/rules/android-audio.md` §2 and the transport
            // that has to act on it is Dart's.
            runOnUiThread { platform.invokeMethod("audioFocus", event.name) }
        }

        platform.setMethodCallHandler { call, result ->
            when (call.method) {
                "isEngineAvailable" -> result.success(installed)

                "startPlayback" -> {
                    val granted = focus?.request() ?: false
                    if (granted) {
                        PlaybackService.start(
                            applicationContext,
                            call.argument<String>("title") ?: "Bandstand",
                        )
                    }
                    result.success(granted)
                }

                "stopPlayback" -> {
                    PlaybackService.stop(applicationContext)
                    focus?.abandon()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        // The service is stopped by the transport, not by the activity: a
        // locked screen destroys the activity and the band must keep playing.
        // Focus is a different matter — it belongs to the process, and the
        // process is still here.
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "dev.bandstand/platform"
    }
}
