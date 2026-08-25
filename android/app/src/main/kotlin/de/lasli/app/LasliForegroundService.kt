package de.lasli.app

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

class LasliForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        val usesMicrophone = intent?.getBooleanExtra(EXTRA_USES_MICROPHONE, false) == true
        val usesConnectedDevice = intent?.getBooleanExtra(EXTRA_USES_CONNECTED_DEVICE, false) == true
        val trainingActive = intent?.getBooleanExtra(EXTRA_TRAINING_ACTIVE, false) == true
        ensureNotificationChannel()
        startMeasurementForeground(usesMicrophone, usesConnectedDevice, trainingActive)
        acquireWakeLock()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    private fun startMeasurementForeground(
        usesMicrophone: Boolean,
        usesConnectedDevice: Boolean,
        trainingActive: Boolean,
    ) {
        val notification = buildNotification(trainingActive)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var type = 0
            if (usesConnectedDevice) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            }
            if (usesMicrophone && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (type != 0) {
                startForeground(NOTIFICATION_ID, notification, type)
                return
            }
        }

        startForeground(NOTIFICATION_ID, notification)
    }

    private fun buildNotification(trainingActive: Boolean): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                Notification.Builder(this)
            }

        return builder
            .setSmallIcon(R.drawable.ic_stat_lasli)
            .setContentTitle(if (trainingActive) "LASLI Audio-Training" else "LASLI misst")
            .setContentText(
                if (trainingActive) {
                    "Trainingsaufnahme laeuft im Hintergrund."
                } else {
                    "Messung laeuft im Hintergrund."
                },
            )
            .setContentIntent(pendingIntent)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "LASLI Messung",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Zeigt laufende LASLI Messungen an."
        manager.createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        val currentWakeLock = wakeLock
        if (currentWakeLock?.isHeld == true) return

        val powerManager = getSystemService(PowerManager::class.java)
        wakeLock = powerManager
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LASLI:MeasurementWakeLock")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    private fun releaseWakeLock() {
        val currentWakeLock = wakeLock
        wakeLock = null
        if (currentWakeLock?.isHeld == true) {
            currentWakeLock.release()
        }
    }

    companion object {
        private const val ACTION_STOP = "de.lasli.app.action.STOP_MEASUREMENT_SERVICE"
        private const val EXTRA_USES_MICROPHONE = "usesMicrophone"
        private const val EXTRA_USES_CONNECTED_DEVICE = "usesConnectedDevice"
        private const val EXTRA_TRAINING_ACTIVE = "trainingActive"
        private const val CHANNEL_ID = "lasli_measurement"
        private const val NOTIFICATION_ID = 24051

        fun start(
            context: Context,
            usesMicrophone: Boolean,
            usesConnectedDevice: Boolean,
            trainingActive: Boolean,
        ) {
            val intent = Intent(context, LasliForegroundService::class.java).apply {
                putExtra(EXTRA_USES_MICROPHONE, usesMicrophone)
                putExtra(EXTRA_USES_CONNECTED_DEVICE, usesConnectedDevice)
                putExtra(EXTRA_TRAINING_ACTIVE, trainingActive)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, LasliForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.stopService(intent)
        }
    }
}
