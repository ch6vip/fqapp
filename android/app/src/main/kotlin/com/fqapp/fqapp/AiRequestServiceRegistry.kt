package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Process-local reference count shared by the Flutter plugin and the service.
 *
 * Keeping the count here (not in Dart) means a service that survived a Flutter
 * engine restart is still accounted for. The stop is delayed briefly so a
 * retry can reuse the same foreground service instead of racing a stop/start.
 */
object AiRequestServiceRegistry {
    private const val TAG = "AiRequestServiceRegistry"
    private const val STOP_DELAY_MS = 1_500L
    private const val START_TIMEOUT_MS = 5_000L

    private val handler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var service: AiRequestService? = null
    private var activeCount = 0
    private var stopRunnable: Runnable? = null
    private var stoppingNormally = false
    private val pending = mutableListOf<(Boolean, String?) -> Unit>()

    @Volatile
    var listener: ((String) -> Unit)? = null

    fun acquire(
        context: Context,
        allowStart: Boolean,
        callback: (Boolean, String?) -> Unit,
    ) {
        handler.post {
            var shouldStart = false
            synchronized(lock) {
                val running = service
                if (running != null) {
                    activeCount++
                    cancelStopLocked()
                    callback(true, null)
                } else if (!allowStart) {
                    callback(false, "APP_IN_BACKGROUND")
                } else {
                    activeCount++
                    pending.add(callback)
                    shouldStart = pending.size == 1
                }
            }
            if (shouldStart) startService(context)
        }
    }

    fun release() {
        handler.post {
            synchronized(lock) {
                if (activeCount > 0) activeCount--
                if (activeCount == 0) scheduleStopLocked()
            }
        }
    }

    fun onStarted(started: AiRequestService) {
        handler.post {
            val callbacks: List<(Boolean, String?) -> Unit>
            synchronized(lock) {
                service = started
                cancelStopLocked()
                callbacks = pending.toList()
                pending.clear()
                if (activeCount == 0) scheduleStopLocked()
            }
            callbacks.forEach { it(true, null) }
        }
    }

    fun onStartFailed(error: Throwable) {
        handler.post {
            val callbacks: List<(Boolean, String?) -> Unit>
            synchronized(lock) {
                activeCount = 0
                callbacks = pending.toList()
                pending.clear()
            }
            val message = error.message ?: error.javaClass.simpleName
            callbacks.forEach { it(false, message) }
        }
    }

    fun onTimedOut() {
        synchronized(lock) { stoppingNormally = true }
        listener?.invoke("timeout")
    }

    fun markStoppingNormally() {
        synchronized(lock) { stoppingNormally = true }
    }

    fun onDestroyed(destroyed: AiRequestService) {
        handler.post {
            var unexpected = false
            synchronized(lock) {
                if (service !== destroyed) return@synchronized
                unexpected = !stoppingNormally
                service = null
                activeCount = 0
                stoppingNormally = false
                cancelStopLocked()
            }
            if (unexpected) listener?.invoke("destroyed")
        }
    }

    fun isStoppingNormally(): Boolean = synchronized(lock) { stoppingNormally }

    private fun startService(context: Context) {
        val intent = Intent(context, AiRequestService::class.java)
            .setAction("com.fqapp.fqapp.ai.ACQUIRE")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (error: Throwable) {
            Log.w(TAG, "startForegroundService failed", error)
            onStartFailed(error)
            return
        }
        handler.postDelayed({ failPendingIfNotStarted() }, START_TIMEOUT_MS)
    }

    private fun failPendingIfNotStarted() {
        synchronized(lock) {
            if (service != null || pending.isEmpty()) return
            Log.w(TAG, "foreground service did not start in time")
            activeCount = 0
            val callbacks = pending.toList()
            pending.clear()
            callbacks.forEach { it(false, "START_TIMEOUT") }
        }
    }

    private fun scheduleStopLocked() {
        if (stopRunnable != null) return
        stoppingNormally = true
        val runnable = Runnable {
            synchronized(lock) {
                stopRunnable = null
                if (activeCount != 0) {
                    stoppingNormally = false
                    return@synchronized
                }
                val current = service
                if (current == null) {
                    stoppingNormally = false
                    return@synchronized
                }
                current.stopSelf()
            }
        }
        stopRunnable = runnable
        handler.postDelayed(runnable, STOP_DELAY_MS)
    }

    private fun cancelStopLocked() {
        val runnable = stopRunnable ?: return
        stopRunnable = null
        stoppingNormally = false
        handler.removeCallbacks(runnable)
    }
}
