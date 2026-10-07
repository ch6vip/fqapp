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
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 听书 / 听视频（listen mode）的前台保活服务：
 * 1. 提高进程优先级，防 MIUI / HyperOS / ColorOS 等厂商系统冻结后台进程导致音频中断。
 * 2. 常驻媒体通知栏卡片：展示当前书名/剧名与章节名，提供「上一章/集」、「播放/暂停」、「下一章/集」快捷控制。
 * 3. 点击通知主体快速拉起应用回到播放页。
 */
class ListenKeepAliveService : Service() {

    private var currentTitle: String = ""
    private var currentEpisode: String = ""
    private var isPlaying: Boolean = true
    private var hasPrev: Boolean = true
    private var hasNext: Boolean = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.listen_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = getString(R.string.listen_channel_name)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action != null) {
            when (action) {
                ACTION_PLAY_PAUSE -> {
                    NativePlayerPlugin.dispatchNotificationAction("playPause")
                    return START_NOT_STICKY
                }
                ACTION_PREV -> {
                    NativePlayerPlugin.dispatchNotificationAction("prev")
                    return START_NOT_STICKY
                }
                ACTION_NEXT -> {
                    NativePlayerPlugin.dispatchNotificationAction("next")
                    return START_NOT_STICKY
                }
                ACTION_STOP -> {
                    NativePlayerPlugin.dispatchNotificationAction("stop")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }

        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: currentTitle.takeIf { it.isNotBlank() }
            ?: getString(R.string.listen_notification_title)
        val episode = intent?.getStringExtra(EXTRA_EPISODE)
            ?: currentEpisode
        val playing = intent?.getBooleanExtra(EXTRA_PLAYING, isPlaying) ?: isPlaying
        val prev = intent?.getBooleanExtra(EXTRA_HAS_PREV, hasPrev) ?: hasPrev
        val next = intent?.getBooleanExtra(EXTRA_HAS_NEXT, hasNext) ?: hasNext

        currentTitle = title
        currentEpisode = episode
        isPlaying = playing
        hasPrev = prev
        hasNext = next

        val notification = buildNotification(title, episode, isPlaying, hasPrev, hasNext)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(
        title: String,
        episode: String,
        playing: Boolean,
        hasPrev: Boolean,
        hasNext: Boolean,
    ): Notification {
        val text = episode.ifBlank { getString(R.string.listen_notification_text) }

        // 点击通知栏卡片拉起主界面
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } else null

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(contentPendingIntent)
            .setOngoing(playing)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        // 上一章 / 上一集
        val prevIntent = PendingIntent.getService(
            this,
            REQUEST_PREV,
            Intent(this, ListenKeepAliveService::class.java).apply { action = ACTION_PREV },
            flags,
        )
        builder.addAction(
            NotificationCompat.Action.Builder(
                android.R.drawable.ic_media_previous,
                getString(R.string.listen_prev),
                prevIntent,
            ).build()
        )

        // 播放 / 暂停
        val playPauseIcon = if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseText = if (playing) getString(R.string.listen_pause) else getString(R.string.listen_play)
        val playPauseIntent = PendingIntent.getService(
            this,
            REQUEST_PLAY_PAUSE,
            Intent(this, ListenKeepAliveService::class.java).apply { action = ACTION_PLAY_PAUSE },
            flags,
        )
        builder.addAction(
            NotificationCompat.Action.Builder(
                playPauseIcon,
                playPauseText,
                playPauseIntent,
            ).build()
        )

        // 下一章 / 下一集
        val nextIntent = PendingIntent.getService(
            this,
            REQUEST_NEXT,
            Intent(this, ListenKeepAliveService::class.java).apply { action = ACTION_NEXT },
            flags,
        )
        builder.addAction(
            NotificationCompat.Action.Builder(
                android.R.drawable.ic_media_next,
                getString(R.string.listen_next),
                nextIntent,
            ).build()
        )

        return builder.build()
    }

    companion object {
        const val CHANNEL_ID = "listen_playback"
        const val NOTIFICATION_ID = 47

        const val EXTRA_TITLE = "title"
        const val EXTRA_EPISODE = "episode"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_HAS_PREV = "hasPrev"
        const val EXTRA_HAS_NEXT = "hasNext"

        const val ACTION_PLAY_PAUSE = "com.fqapp.fqapp.ACTION_PLAY_PAUSE"
        const val ACTION_PREV = "com.fqapp.fqapp.ACTION_PREV"
        const val ACTION_NEXT = "com.fqapp.fqapp.ACTION_NEXT"
        const val ACTION_STOP = "com.fqapp.fqapp.ACTION_STOP"

        private const val REQUEST_PREV = 101
        private const val REQUEST_PLAY_PAUSE = 102
        private const val REQUEST_NEXT = 103
    }
}
