package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Process-local lease registry shared by the Flutter plugin and the service.
 *
 * Every acquire gets an opaque lease id. Release removes only that id, so a
 * late release from a cancelled request cannot decrement a newer service
 * generation. Leases live here rather than in Dart so an engine restart cannot
 * silently drop the reference count.
 */
object AiRequestServiceRegistry {
    private const val TAG = "AiRequestServiceRegistry"
    private const val STOP_DELAY_MS = 1_500L
    private const val START_TIMEOUT_MS = 5_000L

    private data class PendingLease(
        val leaseId: String,
        val callback: (Boolean, String?, String?) -> Unit,
    )

    private val handler = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var service: AiRequestService? = null
    private var accepting = true
    private var stoppingNormally = false
    private var stopRunnable: Runnable? = null
    private var nextLease = 0L
    private val leases = mutableSetOf<String>()
    private val pending = mutableListOf<PendingLease>()

    @Volatile
    var listener: ((String) -> Unit)? = null

    fun acquire(
        context: Context,
        allowStart: Boolean,
        callback: (Boolean, String?, String?) -> Unit,
    ) {
        handler.post {
            var shouldStart = false
            synchronized(lock) {
                val running = service
                if (running != null && accepting) {
                    val leaseId = newLeaseIdLocked()
                    leases.add(leaseId)
                    cancelStopLocked()
                    callback(true, null, leaseId)
                } else if (running != null) {
                    callback(false, "SERVICE_STOPPING", null)
                } else if (!allowStart) {
                    callback(false, "APP_IN_BACKGROUND", null)
                } else {
                    val leaseId = newLeaseIdLocked()
                    leases.add(leaseId)
                    pending.add(PendingLease(leaseId, callback))
                    shouldStart = pending.size == 1
                }
            }
            if (shouldStart) startService(context)
        }
    }

    fun hasLeases(): Boolean = synchronized(lock) { leases.isNotEmpty() }

    fun updateNotification(text: String) {
        handler.post {
            val current = synchronized(lock) { service }
            current?.updateNotification(text)
        }
    }

    fun release(leaseId: String) {
        handler.post {
            synchronized(lock) {
                if (!leases.remove(leaseId)) return@synchronized
                if (leases.isEmpty()) scheduleStopLocked()
            }
        }
    }

    fun onStarted(started: AiRequestService) {
        handler.post {
            val callbacks: List<PendingLease>
            synchronized(lock) {
                service = started
                accepting = true
                cancelStopLocked()
                callbacks = pending.toList()
                pending.clear()
                if (leases.isEmpty()) scheduleStopLocked()
            }
            callbacks.forEach { it.callback(true, null, it.leaseId) }
        }
    }

    fun onStartFailed(error: Throwable) {
        handler.post {
            val callbacks: List<PendingLease>
            synchronized(lock) {
                callbacks = pending.toList()
                pending.clear()
                for (pendingLease in callbacks) leases.remove(pendingLease.leaseId)
            }
            val message = error.message ?: error.javaClass.simpleName
            callbacks.forEach { it.callback(false, message, null) }
        }
    }

    fun onTimedOut() {
        synchronized(lock) {
            accepting = false
            stoppingNormally = true
        }
        listener?.invoke("timeout")
    }

    fun onUserStopped() {
        synchronized(lock) {
            accepting = false
            stoppingNormally = true
        }
        listener?.invoke("stopped")
    }

    fun onDestroyed(destroyed: AiRequestService) {
        handler.post {
            var unexpected = false
            synchronized(lock) {
                if (service !== destroyed) return@synchronized
                unexpected = !stoppingNormally
                service = null
                accepting = true
                stoppingNormally = false
                leases.clear()
                pending.clear()
                cancelStopLocked()
            }
            if (unexpected) listener?.invoke("destroyed")
        }
    }

    fun isStoppingNormally(): Boolean = synchronized(lock) { stoppingNormally }

    private fun newLeaseIdLocked(): String {
        nextLease++
        return "ai-${System.currentTimeMillis()}-$nextLease"
    }

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
            val callbacks = pending.toList()
            pending.clear()
            for (pendingLease in callbacks) leases.remove(pendingLease.leaseId)
            callbacks.forEach { it.callback(false, "START_TIMEOUT", null) }
        }
    }

    private fun scheduleStopLocked() {
        if (stopRunnable != null) return
        stoppingNormally = true
        val runnable = Runnable {
            synchronized(lock) {
                stopRunnable = null
                if (leases.isNotEmpty()) {
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
