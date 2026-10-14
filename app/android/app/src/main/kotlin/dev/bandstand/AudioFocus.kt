package dev.bandstand

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

/**
 * What happened to our claim on the device's audio.
 *
 * `docs/rules/android-audio.md` §2: what a backing band should do depends on
 * *how* focus was lost, not merely that it was.
 */
enum class FocusEvent {
    /** Focus is ours; resume if we paused for a transient loss. */
    GAINED,

    /** Another app took over for good. Stop — the user has left. */
    LOST,

    /** A call or an alarm. Pause, and resume when it is over. */
    LOST_TRANSIENT,

    /** A navigation prompt. Duck, and restore the level after. */
    LOST_TRANSIENT_DUCK,
}

/**
 * Requests and releases audio focus, and reports what the system does with it.
 *
 * Android arbitrates who plays; an app that ignores that plays over the top of
 * phone calls. See `docs/rules/android-audio.md` §2.
 */
class AudioFocus(context: Context, private val onEvent: (FocusEvent) -> Unit) {
    private val manager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        onEvent(
            when (change) {
                AudioManager.AUDIOFOCUS_GAIN -> FocusEvent.GAINED
                AudioManager.AUDIOFOCUS_LOSS -> FocusEvent.LOST
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> FocusEvent.LOST_TRANSIENT
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                    FocusEvent.LOST_TRANSIENT_DUCK
                else -> return@OnAudioFocusChangeListener
            }
        )
    }

    /**
     * `MEDIA` / `MUSIC` is what a backing track is, and it is what tells the
     * system to duck a navigation prompt over us rather than interrupt.
     */
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private val request: AudioFocusRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(listener)
                .setWillPauseWhenDucked(false)
                .build()
        } else {
            null
        }

    /** Ask for focus. Returns true when the system granted it. */
    fun request(): Boolean {
        val result = request?.let { manager.requestAudioFocus(it) }
            ?: @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /** Give focus back. */
    fun abandon() {
        request?.let { manager.abandonAudioFocusRequest(it) }
            ?: @Suppress("DEPRECATION") manager.abandonAudioFocus(listener)
    }
}
