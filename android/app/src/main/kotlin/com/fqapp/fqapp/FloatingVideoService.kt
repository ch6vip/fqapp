package com.fqapp.fqapp

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.support.v4.media.MediaMetadataCompat
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media.app.NotificationCompat.MediaStyle
import kotlin.math.abs

/**
 * 视频悬浮窗服务（#24）：切到后台或锁屏时把播放画面搬进系统悬浮窗继续播，
 * 而不是停掉。播放器实例仍由 NativePlayerPlugin 持有；本服务只负责：
 * 1. 悬浮窗（WindowManager + SurfaceView + 控制条），可拖动、松手贴边；
 * 2. 前台保活 + 媒体通知 + MediaSession；
 * 3. 把悬浮窗 / 通知的按钮动作转发给 NativePlayerPlugin，由 Dart 侧处理；
 * 4. 耳机断开由插件全局的 becoming-noisy 接收器处理（会暂停全部播放器）。
 *
 * 启动时机：Dart 在应用进入 inactive（仍在前台过渡态，startForegroundService
 * 还合法）时启动本服务，悬浮窗先保持隐藏；确认切后台（hidden）后再显示；
 * 回前台时 Dart 调 stopFloating 恢复 Flutter 纹理并停服务。直接在 hidden
 * 后启动前台服务会在 Android 12+ 触发 ForegroundServiceStartNotAllowed，
 * 所以不能等到 hidden 才启动。
 */
class FloatingVideoService : Service() {

    companion object {
        const val CHANNEL_ID = "floating_video"
        const val NOTIFICATION_ID = 48

        const val EXTRA_OWNER = "owner"
        const val EXTRA_TITLE = "title"
        const val EXTRA_EPISODE = "episode"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_HAS_PREV = "hasPrev"
        const val EXTRA_HAS_NEXT = "hasNext"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_SPEED = "speed"
        const val EXTRA_VIDEO_WIDTH = "videoWidth"
        const val EXTRA_VIDEO_HEIGHT = "videoHeight"

        const val ACTION_START = "com.fqapp.fqapp.FLOATING_START"
        const val ACTION_SHOW = "com.fqapp.fqapp.FLOATING_SHOW"
        const val ACTION_UPDATE = "com.fqapp.fqapp.FLOATING_UPDATE"
        const val ACTION_PLAY_PAUSE = "com.fqapp.fqapp.FLOATING_PLAY_PAUSE"
        const val ACTION_PREV = "com.fqapp.fqapp.FLOATING_PREV"
        const val ACTION_NEXT = "com.fqapp.fqapp.FLOATING_NEXT"
        const val ACTION_CLOSE = "com.fqapp.fqapp.FLOATING_CLOSE"
        const val ACTION_FULLSCREEN = "com.fqapp.fqapp.FLOATING_FULLSCREEN"

        /** Dart 侧 remote handler 认识的动作名；通知按钮与悬浮窗按钮共用一份。 */
        private const val ACTION_NAME_PLAY_PAUSE = "playPause"
        private const val ACTION_NAME_PREV = "prev"
        private const val ACTION_NAME_NEXT = "next"
        private const val ACTION_NAME_STOP = "stop"
        private const val ACTION_NAME_FULLSCREEN = "fullscreen"

        private var activeService: FloatingVideoService? = null
        private val serviceHandler = Handler(Looper.getMainLooper())

        fun start(context: Context, owner: Long) {
            val intent = Intent(context, FloatingVideoService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_OWNER, owner)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun show(owner: Long) = command(owner, ACTION_SHOW, emptyMap())

        fun update(owner: Long, extras: Map<String, Any?>) = command(owner, ACTION_UPDATE, extras)

        private fun command(owner: Long, action: String, extras: Map<String, Any?>) {
            val intent = Intent().apply {
                this.action = action
                putExtra(EXTRA_OWNER, owner)
                putExtras(this, extras)
            }
            onMain { activeService?.applyCommand(intent) }
        }

        fun retire(owner: Long) = onMain { activeService?.retireOwned(owner) }

        private fun onMain(action: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) action()
            else serviceHandler.post { action() }
        }

        private fun putExtras(intent: Intent, extras: Map<String, Any?>) {
            (extras[EXTRA_TITLE] as? String)?.let { intent.putExtra(EXTRA_TITLE, it) }
            (extras[EXTRA_EPISODE] as? String)?.let { intent.putExtra(EXTRA_EPISODE, it) }
            (extras[EXTRA_PLAYING] as? Boolean)?.let { intent.putExtra(EXTRA_PLAYING, it) }
            (extras[EXTRA_HAS_PREV] as? Boolean)?.let { intent.putExtra(EXTRA_HAS_PREV, it) }
            (extras[EXTRA_HAS_NEXT] as? Boolean)?.let { intent.putExtra(EXTRA_HAS_NEXT, it) }
            (extras[EXTRA_POSITION_MS] as? Number)?.let {
                intent.putExtra(EXTRA_POSITION_MS, it.toLong())
            }
            (extras[EXTRA_DURATION_MS] as? Number)?.let {
                intent.putExtra(EXTRA_DURATION_MS, it.toLong())
            }
            (extras[EXTRA_SPEED] as? Number)?.let { intent.putExtra(EXTRA_SPEED, it.toFloat()) }
            (extras[EXTRA_VIDEO_WIDTH] as? Number)?.let {
                intent.putExtra(EXTRA_VIDEO_WIDTH, it.toInt())
            }
            (extras[EXTRA_VIDEO_HEIGHT] as? Number)?.let {
                intent.putExtra(EXTRA_VIDEO_HEIGHT, it.toInt())
            }
        }
    }

    private var ownedOwner: Long? = null
    private var lastStartId = 0
    private var edgeAnimator: android.animation.ValueAnimator? = null
    private var windowManager: WindowManager? = null
    private var params: WindowManager.LayoutParams? = null
    private var floatingView: FrameLayout? = null
    private var surfaceView: SurfaceView? = null
    private var playPauseButton: ImageButton? = null
    private var controlsBar: View? = null
    private var overlayVisible = false
    private var controlsVisible = true
    private var viewAdded = false
    private var mediaSession: MediaSessionCompat? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var hideControlsRunnable: Runnable? = null

    private var currentTitle = ""
    private var currentEpisode = ""
    private var isPlaying = true
    private var hasPrev = true
    private var hasNext = true
    private var positionMs = 0L
    private var durationMs = 0L
    private var speed = 1f
    private var videoWidth = 0
    private var videoHeight = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        activeService = this
        createNotificationChannel()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        val owner = ownedOwner
        try {
            if (owner != null) NativePlayerPlugin.retireFloatingOwner(owner, pause = true)
        } catch (error: Throwable) {
            android.util.Log.w("FloatingVideoService", "task cleanup failed: ${error.javaClass.simpleName}")
        } finally {
            try { stopIfIdle(lastStartId) }
            finally { super.onTaskRemoved(rootIntent) }
        }
    }

    override fun onDestroy() {
        val owner = ownedOwner
        ownedOwner = null
        val wasActiveService = activeService === this
        if (wasActiveService) activeService = null
        try {
            clearResources(removeNotification = wasActiveService)
        } catch (error: Throwable) {
            android.util.Log.w("FloatingVideoService", "overlay cleanup failed: ${error.javaClass.simpleName}")
        } finally {
            try {
                if (owner != null) NativePlayerPlugin.retireFloatingOwner(owner, pause = true)
            } catch (error: Throwable) {
                android.util.Log.w("FloatingVideoService", "owner cleanup failed: ${error.javaClass.simpleName}")
            } finally {
                super.onDestroy()
            }
        }
    }

    private fun retireOwned(owner: Long) {
        try {
            if (ownedOwner == owner) {
                ownedOwner = null
                clearResources()
            }
        } finally {
            stopIfIdle(lastStartId)
        }
    }

    private fun stopIfIdle(startId: Int) {
        if (ownedOwner == null && NativePlayerPlugin.desiredFloatingOwner() == null && startId > 0) {
            stopSelfResult(startId)
        }
    }

    private fun clearResources(removeNotification: Boolean = activeService === this) {
        var cleanupError: Throwable? = null
        fun clean(action: () -> Unit) {
            try { action() } catch (error: Throwable) {
                if (cleanupError == null) cleanupError = error
            }
        }
        clean { hideControlsRunnable?.let(mainHandler::removeCallbacks) }
        hideControlsRunnable = null
        clean { edgeAnimator?.cancel() }
        edgeAnimator = null
        var removalError: Throwable? = null
        try {
            if (viewAdded && floatingView != null) windowManager?.removeView(floatingView)
        } catch (_: IllegalArgumentException) {
            // A view already removed by WindowManager has no remaining ownership.
        } catch (error: Throwable) {
            removalError = error
        }
        if (removalError == null) {
            viewAdded = false
            floatingView = null
            surfaceView = null
            params = null
            controlsBar = null
            playPauseButton = null
            windowManager = null
        }
        overlayVisible = false
        controlsVisible = true
        clean { mediaSession?.release() }
        mediaSession = null
        if (removeNotification) {
            clean {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
                else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            }
            clean { (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIFICATION_ID) }
        }
        (removalError ?: cleanupError)?.let { throw it }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    getString(R.string.floating_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = getString(R.string.floating_channel_name)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        val owner = intent?.getLongExtra(EXTRA_OWNER, 0L) ?: 0L
        if (owner <= 0 || NativePlayerPlugin.desiredFloatingOwner() != owner) {
            // A queued foreground START must settle its own Android startup debt.
            // stopSelfResult cannot stop a newer start ID already queued by AMS.
            if (intent?.action == ACTION_START) stopSelfResult(startId)
            else stopIfIdle(startId)
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START) {
            applyCommand(intent ?: return START_NOT_STICKY)
            return START_NOT_STICKY
        }
        try {
            if (ownedOwner != owner) {
                ownedOwner = null
                clearResources()
                ownedOwner = owner
                currentTitle = ""
                currentEpisode = ""
                isPlaying = true
                hasPrev = true
                hasNext = true
                positionMs = 0L
                durationMs = 0L
                speed = 1f
                videoWidth = 0
                videoHeight = 0
            }
            val state = NativePlayerPlugin.floatingState(owner)
                ?: throw IllegalStateException("Floating owner retired")
            readState(Intent().apply { putExtras(this, state) })
            if (floatingView == null) createOverlay(owner)
            val notification = buildNotification()
            syncPlaybackState()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else startForeground(NOTIFICATION_ID, notification)
            if (NativePlayerPlugin.floatingVisible(owner)) showOverlay(owner)
        } catch (error: Throwable) {
            android.util.Log.w("FloatingVideoService", "floating startup failed: ${error.javaClass.simpleName}")
            try { NativePlayerPlugin.retireFloatingOwner(owner, pause = true) }
            catch (cleanup: Throwable) {
                android.util.Log.w("FloatingVideoService", "startup cleanup failed: ${cleanup.javaClass.simpleName}")
            }
            finally { stopIfIdle(startId) }
        }
        return START_NOT_STICKY
    }

    private fun applyCommand(intent: Intent) {
        val owner = intent.getLongExtra(EXTRA_OWNER, 0L)
        if (ownedOwner != owner || NativePlayerPlugin.desiredFloatingOwner() != owner) return
        when (intent.action) {
            ACTION_SHOW -> showOverlay(owner)
            ACTION_UPDATE -> {
                readState(intent)
                refreshNotification()
                syncPlayPauseButton()
            }
            ACTION_PLAY_PAUSE -> remoteAction(owner, ACTION_NAME_PLAY_PAUSE)
            ACTION_PREV -> remoteAction(owner, ACTION_NAME_PREV)
            ACTION_NEXT -> remoteAction(owner, ACTION_NAME_NEXT)
            ACTION_CLOSE -> remoteAction(owner, ACTION_NAME_STOP)
            ACTION_FULLSCREEN -> remoteAction(owner, ACTION_NAME_FULLSCREEN)
        }
    }

    private fun remoteAction(owner: Long, action: String) {
        if (ownedOwner != owner || NativePlayerPlugin.desiredFloatingOwner() != owner) return
        if (action == ACTION_NAME_FULLSCREEN) {
            hideOverlay()
            bringAppToFront()
        }
        try {
            NativePlayerPlugin.dispatchFloatingAction(owner, action)
        } finally {
            if (action == ACTION_NAME_STOP) NativePlayerPlugin.retireFloatingOwner(owner, pause = true)
        }
    }

    private fun readState(intent: Intent?) {
        intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }?.let {
            currentTitle = it
        }
        intent?.getStringExtra(EXTRA_EPISODE)?.let { currentEpisode = it }
        if (intent?.hasExtra(EXTRA_PLAYING) == true) {
            isPlaying = intent.getBooleanExtra(EXTRA_PLAYING, isPlaying)
        }
        if (intent?.hasExtra(EXTRA_HAS_PREV) == true) {
            hasPrev = intent.getBooleanExtra(EXTRA_HAS_PREV, hasPrev)
        }
        if (intent?.hasExtra(EXTRA_HAS_NEXT) == true) {
            hasNext = intent.getBooleanExtra(EXTRA_HAS_NEXT, hasNext)
        }
        if (intent?.hasExtra(EXTRA_POSITION_MS) == true) {
            positionMs = intent.getLongExtra(EXTRA_POSITION_MS, positionMs)
        }
        if (intent?.hasExtra(EXTRA_DURATION_MS) == true) {
            durationMs = intent.getLongExtra(EXTRA_DURATION_MS, durationMs)
        }
        if (intent?.hasExtra(EXTRA_SPEED) == true) {
            speed = intent.getFloatExtra(EXTRA_SPEED, speed)
        }
        if (intent?.hasExtra(EXTRA_VIDEO_WIDTH) == true) {
            videoWidth = intent.getIntExtra(EXTRA_VIDEO_WIDTH, videoWidth)
        }
        if (intent?.hasExtra(EXTRA_VIDEO_HEIGHT) == true) {
            videoHeight = intent.getIntExtra(EXTRA_VIDEO_HEIGHT, videoHeight)
        }
    }

    private fun createOverlay(owner: Long) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        windowManager = wm
        val metrics = resources.displayMetrics
        val screenWidth = metrics.widthPixels
        val screenHeight = metrics.heightPixels
        // 竖屏剧用窄高窗，横屏用宽窗；拿不到视频尺寸时默认 16:9。
        val windowWidth = (screenWidth * 0.62f).toInt()
        val windowHeight = if (videoWidth > 0 && videoHeight > 0) {
            (windowWidth * videoHeight / videoWidth.toFloat()).toInt()
                .coerceIn(screenHeight / 5, screenHeight * 3 / 4)
        } else {
            windowWidth * 9 / 16
        }
        val container = FrameLayout(this)
        val surface = SurfaceView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
        }
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            private var surfaceId = 0L
            override fun surfaceCreated(holder: SurfaceHolder) {
                val createdId = NativePlayerPlugin.allocateFloatingSurface()
                surfaceId = createdId
                NativePlayerPlugin.dispatchFloatingSurfaceReady(owner, createdId, holder.surface)
            }

            override fun surfaceChanged(
                holder: SurfaceHolder,
                format: Int,
                width: Int,
                height: Int,
            ) = Unit

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                val destroyedId = surfaceId
                NativePlayerPlugin.dispatchFloatingSurfaceDestroyed(owner, destroyedId)
            }
        })
        surfaceView = surface
        container.addView(surface)

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(0x99000000.toInt())
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM,
            )
            setPadding(8, 4, 8, 4)
        }
        val playPause = ImageButton(this).apply {
            setImageResource(
                if (isPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
            )
            setBackgroundColor(0x00000000)
            setOnClickListener {
                remoteAction(owner, ACTION_NAME_PLAY_PAUSE)
            }
        }
        playPauseButton = playPause
        val titleView = TextView(this).apply {
            text = currentEpisode.ifBlank { currentTitle }
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 12f
            maxLines = 1
            layoutParams = LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f,
            )
        }
        val fullscreen = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_view)
            setBackgroundColor(0x00000000)
            setOnClickListener {
                remoteAction(owner, ACTION_NAME_FULLSCREEN)
            }
        }
        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundColor(0x00000000)
            setOnClickListener {
                remoteAction(owner, ACTION_NAME_STOP)
            }
        }
        bar.addView(playPause)
        bar.addView(titleView)
        bar.addView(fullscreen)
        bar.addView(close)
        controlsBar = bar
        container.addView(bar)

        val closeTop = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setBackgroundColor(0x66000000.toInt())
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP or Gravity.END,
            )
            setOnClickListener {
                remoteAction(owner, ACTION_NAME_STOP)
            }
        }
        container.addView(closeTop)

        container.setOnTouchListener(FloatingTouchListener(owner, container))
        val layoutParams = WindowManager.LayoutParams(
            windowWidth,
            windowHeight,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.START or Gravity.TOP
            x = (screenWidth - windowWidth) / 2
            y = screenHeight / 4
        }
        params = layoutParams
        floatingView = container
        // 先不加到 WindowManager：等 Dart 确认切后台（hidden）后再 showOverlay。
        scheduleHideControls()
    }

    private fun showOverlay(owner: Long) {
        if (ownedOwner != owner || NativePlayerPlugin.desiredFloatingOwner() != owner) return
        val view = floatingView ?: return
        val lp = params ?: return
        overlayVisible = true
        if (!viewAdded) {
            try {
                windowManager?.addView(view, lp)
                viewAdded = true
            } catch (error: Throwable) {
                NativePlayerPlugin.retireFloatingOwner(owner, pause = true)
                return
            }
        }
        view.visibility = View.VISIBLE
        controlsBar?.visibility = View.VISIBLE
        controlsVisible = true
        scheduleHideControls()
    }

    private fun hideOverlay() {
        overlayVisible = false
        floatingView?.visibility = View.GONE
    }

    private fun scheduleHideControls() {
        hideControlsRunnable?.let(mainHandler::removeCallbacks)
        val owner = ownedOwner
        val view = floatingView
        val runnable = Runnable {
            if (owner != null && ownedOwner == owner && floatingView === view && overlayVisible) {
                controlsBar?.visibility = View.GONE
                controlsVisible = false
            }
        }
        hideControlsRunnable = runnable
        mainHandler.postDelayed(runnable, 3000)
    }

    private fun toggleControls() {
        controlsVisible = !controlsVisible
        controlsBar?.visibility = if (controlsVisible) View.VISIBLE else View.GONE
        if (controlsVisible) scheduleHideControls()
    }

    private fun syncPlayPauseButton() {
        playPauseButton?.setImageResource(
            if (isPlaying) android.R.drawable.ic_media_pause
            else android.R.drawable.ic_media_play,
        )
    }

    private fun bringAppToFront() {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        } ?: return
        try {
            startActivity(launch)
        } catch (_: Throwable) {
        }
    }

    private inner class FloatingTouchListener(private val owner: Long, private val view: View) : View.OnTouchListener {
        private var initialTouchX = 0f
        private var initialTouchY = 0f
        private var initialX = 0
        private var initialY = 0
        private var isClick = true

        @SuppressLint("ClickableViewAccessibility")
        override fun onTouch(v: View, event: MotionEvent): Boolean {
            if (ownedOwner != owner || floatingView !== view || NativePlayerPlugin.desiredFloatingOwner() != owner) return false
            val lp = params ?: return false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isClick = true
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    initialX = lp.x
                    initialY = lp.y
                }
                MotionEvent.ACTION_MOVE -> {
                    val deltaX = event.rawX - initialTouchX
                    val deltaY = event.rawY - initialTouchY
                    if (abs(deltaX) > 20 || abs(deltaY) > 20) {
                        isClick = false
                        lp.x = (initialX + deltaX).toInt()
                        lp.y = (initialY + deltaY).toInt()
                        updateViewPosition()
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (isClick) {
                        toggleControls()
                    } else {
                        snapToEdge()
                    }
                }
            }
            return true
        }
    }

    private fun updateViewPosition() {
        val view = floatingView ?: return
        val lp = params ?: return
        if (!viewAdded) return
        try {
            windowManager?.updateViewLayout(view, lp)
        } catch (_: Throwable) {
        }
    }

    private fun snapToEdge() {
        val lp = params ?: return
        val view = floatingView ?: return
        val screenWidth = resources.displayMetrics.widthPixels
        val screenHeight = resources.displayMetrics.heightPixels
        val targetX = if (lp.x + view.width / 2 > screenWidth / 2) {
            screenWidth - view.width - 16
        } else {
            16
        }
        val targetY = lp.y.coerceIn(16, (screenHeight - view.height - 16).coerceAtLeast(16))
        val startX = lp.x
        val startY = lp.y
        val owner = ownedOwner
        edgeAnimator?.cancel()
        val animator = android.animation.ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 180
            addUpdateListener { animation ->
                if (ownedOwner != owner || floatingView !== view) return@addUpdateListener
                val t = animation.animatedValue as Float
                lp.x = (startX + (targetX - startX) * t).toInt()
                lp.y = (startY + (targetY - startY) * t).toInt()
                updateViewPosition()
            }
        }
        edgeAnimator = animator
        animator.start()
    }

    private fun refreshNotification() {
        val notification = buildNotification()
        syncPlaybackState()
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        } catch (_: Throwable) {
        }
    }

    private fun buildNotification(): Notification {
        val owner = ownedOwner ?: throw IllegalStateException("No floating notification owner")
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(EXTRA_OWNER, owner)
        }?.let {
            PendingIntent.getActivity(this, 0, it, flags)
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(currentTitle.ifBlank { getString(R.string.floating_notification_title) })
            .setContentText(currentEpisode.ifBlank { getString(R.string.floating_notification_text) })
            .setContentIntent(contentIntent)
            .setOngoing(isPlaying)
            .setSilent(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setStyle(
                MediaStyle()
                    .setMediaSession(ensureMediaSession().sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
        fun action(icon: Int, label: String, intentAction: String, requestCode: Int) {
            val pending = PendingIntent.getService(
                this,
                requestCode,
                Intent(this, FloatingVideoService::class.java).apply {
                    action = intentAction
                    putExtra(EXTRA_OWNER, owner)
                    data = Uri.parse("fqapp-floating://$owner/$intentAction")
                },
                flags,
            )
            builder.addAction(NotificationCompat.Action.Builder(icon, label, pending).build())
        }
        action(android.R.drawable.ic_media_previous, getString(R.string.listen_prev), ACTION_PREV, 201)
        action(
            if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            if (isPlaying) getString(R.string.listen_pause) else getString(R.string.listen_play),
            ACTION_PLAY_PAUSE,
            202,
        )
        action(android.R.drawable.ic_media_next, getString(R.string.listen_next), ACTION_NEXT, 203)
        action(android.R.drawable.ic_menu_close_clear_cancel, getString(R.string.listen_stop), ACTION_CLOSE, 204)
        return builder.build()
    }

    private fun ensureMediaSession(): MediaSessionCompat {
        mediaSession?.let { return it }
        val owner = ownedOwner ?: throw IllegalStateException("No floating media-session owner")
        val session = MediaSessionCompat(this, "fqapp-floating-video-$owner")
        session.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() =
                remoteAction(owner, ACTION_NAME_PLAY_PAUSE)

            override fun onPause() =
                remoteAction(owner, ACTION_NAME_PLAY_PAUSE)

            override fun onSkipToPrevious() =
                remoteAction(owner, ACTION_NAME_PREV)

            override fun onSkipToNext() =
                remoteAction(owner, ACTION_NAME_NEXT)

            override fun onStop() =
                remoteAction(owner, ACTION_NAME_STOP)
        })
        session.setSessionActivity(
            packageManager.getLaunchIntentForPackage(packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_OWNER, owner)
            }?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) },
        )
        session.isActive = true
        mediaSession = session
        return session
    }

    private fun syncPlaybackState() {
        val session = ensureMediaSession()
        session.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, currentTitle)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, currentEpisode)
                .putLong(
                    MediaMetadataCompat.METADATA_KEY_DURATION,
                    durationMs.coerceAtLeast(0L),
                )
                .build(),
        )
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
            PlaybackStateCompat.ACTION_STOP
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED,
                    positionMs.coerceAtLeast(0L),
                    if (speed > 0f) speed else 1f,
                )
                .build(),
        )
    }
}
