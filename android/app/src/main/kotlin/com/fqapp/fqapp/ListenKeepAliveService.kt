package com.fqapp.fqapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * 听视频（listen mode）的前台保活服务：只负责把进程提到前台优先级，
 * 防 MIUI 等厂商系统冻结后台进程导致音频中断。不拥有播放器——播放仍由
 * NativePlayerPlugin 里的 ExoPlayer 实例承担，本服务与它无生命周期耦合。
 *
 * 语义对齐官方 `jm3.d0.y()` 的听书模式页（独立于视频页的音频形态）；
 * 官方用媒体会话通知，本地先给一条常驻低优先级通知（`listen_playback`
 * 通道），后续接 media3-session 再升级成媒体样式。
 */
class ListenKeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        getString(R.string.listen_channel_name),
                        NotificationManager.IMPORTANCE_LOW,
                    )
                )
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: getString(R.string.listen_notification_title)
        val episode = intent?.getStringExtra(EXTRA_EPISODE).orEmpty()
        val notification = buildNotification(title, episode)
        // API 29+ 必须声明 mediaPlayback 类型；低版本走普通 startForeground。
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

    private fun buildNotification(title: String, episode: String): Notification {
        val text = episode.ifBlank { getString(R.string.listen_notification_text) }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "listen_playback"
        const val NOTIFICATION_ID = 47
        const val EXTRA_TITLE = "title"
        const val EXTRA_EPISODE = "episode"
    }
}
