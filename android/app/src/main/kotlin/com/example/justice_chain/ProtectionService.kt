package com.example.justice_chain

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Background protection (step 6b): a foreground service that keeps the app's
 * process, and with it the cached Flutter engine (MainActivity), running
 * while the phone is locked or Sakshya is swiped away. The AI keeps listening
 * in Dart; this service only holds the process, the permanent notification
 * and the microphone/camera access Android gives a foreground service.
 *
 * Android only lets a microphone or camera service start while the app is on
 * screen, so it is started from Dart when monitoring starts, never restarted
 * by the system (START_NOT_STICKY: a restart from the background would get no
 * microphone anyway).
 */
class ProtectionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!granted(this, Manifest.permission.RECORD_AUDIO)) {
            stopSelf()
            return START_NOT_STICKY
        }
        applyDisguise(intent?.getBooleanExtra(EXTRA_DISGUISED, false) ?: false)
        // The AI runs on the CPU between audio buffers; without this the CPU
        // may sleep with the screen off.
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Sakshya:protection")
                .apply { setReferenceCounted(false); acquire() }
        }
        instance = this
        running = true
        return START_NOT_STICKY
    }

    /**
     * Android heads every notification with the app's real name and icon,
     * which an app can't change. So in disguise mode the service moves to a
     * channel created switched off: nothing shows in the shade, and the
     * service keeps running (Android 13+). The normal notification is removed.
     */
    private fun applyDisguise(disguised: Boolean) {
        val (show, hide) = if (disguised) QUIET_NOTIFICATION_ID to NOTIFICATION_ID else NOTIFICATION_ID to QUIET_NOTIFICATION_ID
        ServiceCompat.startForeground(this, show, buildNotification(this, disguised), foregroundTypes())
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(hide)
    }

    /** Swiped away from recent apps: keep protecting, the engine lives on. */
    override fun onTaskRemoved(rootIntent: Intent?) = Unit

    override fun onDestroy() {
        wakeLock?.release()
        wakeLock = null
        instance = null
        running = false
        super.onDestroy()
    }

    /** Camera only if it is granted: Android 14+ refuses a camera service without it. */
    private fun foregroundTypes(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if (granted(this, Manifest.permission.CAMERA)) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        return types
    }

    companion object {
        private const val CHANNEL_ID = "protection"
        private const val QUIET_CHANNEL_ID = "protection_quiet"
        private const val NOTIFICATION_ID = 1101
        private const val QUIET_NOTIFICATION_ID = 1102
        private const val EXTRA_DISGUISED = "disguised"

        @Volatile
        var running = false
            private set

        /** The running service, for switching its notification (same process, main thread). */
        private var instance: ProtectionService? = null

        /** Throws if Android refuses (e.g. ForegroundServiceStartNotAllowedException from the background). */
        fun start(context: Context, disguised: Boolean) {
            ContextCompat.startForegroundService(
                context, Intent(context, ProtectionService::class.java).putExtra(EXTRA_DISGUISED, disguised))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ProtectionService::class.java))
        }

        /** Swaps the notification for disguise mode without restarting the service. */
        fun setDisguised(disguised: Boolean) {
            instance?.applyDisguise(disguised)
        }

        private fun granted(context: Context, permission: String) =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

        /**
         * Normal mode says what it is. Disguise mode goes to the switched-off
         * channel; should someone switch it on, it still reads like a
         * calculator's reminder and stays off the lock screen.
         */
        private fun buildNotification(context: Context, disguised: Boolean): Notification {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                // Neutral names: they show in the app's notification settings in disguise mode too.
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Running in background", NotificationManager.IMPORTANCE_LOW)
                        .apply { setShowBadge(false) })
                // Created switched off; Android keeps a channel's importance once created.
                manager.createNotificationChannel(
                    NotificationChannel(QUIET_CHANNEL_ID, "Background", NotificationManager.IMPORTANCE_NONE)
                        .apply { setShowBadge(false) })
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = NotificationCompat.Builder(context, if (disguised) QUIET_CHANNEL_ID else CHANNEL_ID)
                .setOngoing(true)
                .setShowWhen(false)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(open)
            return if (disguised) {
                builder
                    .setSmallIcon(R.drawable.ic_calculator_monochrome)
                    .setContentTitle("Calculator")
                    .setContentText("New calculations? The numbers miss you.")
                    .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                    .build()
            } else {
                builder
                    .setSmallIcon(R.drawable.ic_launcher_monochrome)
                    .setContentTitle("Sakshya is protecting you")
                    .setContentText("Listening for danger. Recordings are sealed automatically.")
                    .build()
            }
        }
    }
}
