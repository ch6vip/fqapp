package com.fqapp.fqapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process and network alive while an AI HTTP request is in flight.
 *
 * The service is reference-counted by [acquire]/[release]. It is started only
 * while an Activity is resumed (Android 12+ rejects background FGS starts);
 * once running, another request may join from the background.
 *
 * The notification intentionally contains no chapter title or body text.
 */
class AiRequestService : Service() {
    private var foregroundStarted = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var statusText: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ACQUIRE -> startOrJoin(startId)
            ACTION_STOP -> {
                Log.w(TAG, "stopped by notification")
                AiRequestServiceRegistry.onUserStopped()
                stopSelf()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startOrJoin(startId: Int) {
        try {
            if (!foregroundStarted) {
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ServiceCompat.startForeground(
                        this,
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                foregroundStarted = true
            }
            acquireWakeLock()
            AiRequestServiceRegistry.onStarted(this)
        } catch (error: Throwable) {
            Log.e(TAG, "startForeground failed", error)
            AiRequestServiceRegistry.onStartFailed(error)
            stopSelf(startId)
        }
    }

    /** Updates the visible status without changing the foreground lease. */
    fun updateNotification(text: String) {
        statusText = text
        if (!foregroundStarted) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 caps dataSync foreground services. Never leave a stuck
        // notification behind; the next app start reconciles the request ledger.
        Log.w(TAG, "dataSync foreground service timed out")
        releaseWakeLock()
        AiRequestServiceRegistry.onTimedOut()
        stopSelf()
    }

    override fun onDestroy() {
        val expected = AiRequestServiceRegistry.isStoppingNormally()
        AiRequestServiceRegistry.onDestroyed(this)
        if (!expected) Log.w(TAG, "service destroyed unexpectedly")
        foregroundStarted = false
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "fqapp:ai-request",
        ).apply {
            setReferenceCounted(false)
            acquire(10 * 60 * 1000L)
        }
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        wakeLock = null
        if (lock.isHeld) lock.release()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.ai_request_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.ai_request_channel_name)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, AiRequestService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.ai_request_notification_title))
            .setContentText(
                statusText ?: getString(R.string.ai_request_notification_text)
            )
            .setContentIntent(contentIntent)
            .addAction(0, getString(R.string.ai_request_stop), stopIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        private const val TAG = "AiRequestService"
        private const val CHANNEL_ID = "ai_request"
        private const val NOTIFICATION_ID = 0x41A1
        private const val ACTION_ACQUIRE = "com.fqapp.fqapp.ai.ACQUIRE"
        private const val ACTION_STOP = "com.fqapp.fqapp.ai.STOP"
    }
}
