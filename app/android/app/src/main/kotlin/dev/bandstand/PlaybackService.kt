package dev.bandstand

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process alive while the band is playing.
 *
 * §10's acceptance is a 90-minute set with the screen locked and unlocked
 * repeatedly. A backgrounded Android app is killable at any moment and a locked
 * screen backgrounds it, so without this the band stops somewhere in the second
 * tune.
 *
 * The service does **not** own the audio: the Rust engine owns the stream and
 * the transport, and this exists to tell Android the process is doing something
 * the user asked for. See `docs/rules/android-audio.md` §3.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Bandstand"
        // Android kills the app if `startForeground` is not called within a few
        // seconds of the service starting, so it happens before anything else.
        val notification = buildNotification(title)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        acquireWakeLock()
        // START_NOT_STICKY: if Android kills us under memory pressure, the band
        // has stopped and restarting the service without the transport running
        // would show a notification for silence.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    /** A partial lock, so a sleeping CPU does not stop the band (§4). */
    private fun acquireWakeLock() {
        if (wakeLock != null) {
            return
        }
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "bandstand:playback",
        ).apply {
            setReferenceCounted(false)
            acquire(MAXIMUM_SET_MILLIS)
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Playback",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while the band is playing."
                setShowBadge(false)
            }
        )
    }

    /**
     * Not decoration: Android will not allow the service without one, and it is
     * how a player who has locked the tablet stops the band without unlocking
     * it.
     */
    private fun buildNotification(title: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
            },
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setContentTitle(title)
            .setContentText("Playing")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Stop",
                    stop,
                ).build()
            )
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "bandstand.playback"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "dev.bandstand.STOP"
        private const val EXTRA_TITLE = "title"

        /**
         * The longest a wake lock is held before Android reclaims it.
         *
         * Two hours: longer than the 90-minute set §10 asks for, with room, and
         * short enough that a bug cannot flatten a battery overnight.
         */
        private const val MAXIMUM_SET_MILLIS = 2L * 60 * 60 * 1000

        /** Start it. Called when the transport starts, not when the app opens. */
        fun start(context: Context, title: String) {
            val intent = Intent(context, PlaybackService::class.java)
                .putExtra(EXTRA_TITLE, title)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Stop it. Called when the transport stops. */
        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
