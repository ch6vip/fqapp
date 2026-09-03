package com.fqapp.fqapp

import android.util.Log

/**
 * Bridge to the native  backend.
 *
 * The backend ships as liblegacy.so under jniLibs/arm64-v8a/. It exposes three
 * exported JNI entry points (see /jni.go):
 *   - startBackend(configPath, poolPath, filterPath)
 *   - stopBackend()
 *   - status()  ->  "starting" | "running" | "failed: <message>"
 *
 * The host calls startBackend on a background thread; the Go side runs the
 * HTTP server in a goroutine and returns immediately. Poll status() (or hit
 * the /health endpoint) to learn whether startup succeeded.
 */
interface BackendNativeApi {
    fun startBackend(configPath: String, poolPath: String, filterPath: String)
    fun stopBackend()
    fun status(): String
}

class BackendNative : BackendNativeApi {
    companion object {
        private const val TAG = "BackendNative"

        init {
            try {
                System.loadLibrary("")
                Log.i(TAG, "liblegacy.so loaded")
            } catch (e: UnsatisfiedLinkError) {
                Log.e(TAG, "failed to load liblegacy.so", e)
                throw e
            }
        }
    }

    /** Start the backend with the given runtime file paths. Returns immediately. */
    override external fun startBackend(configPath: String, poolPath: String, filterPath: String)

    /** Stop the backend (closes the HTTP server). */
    override external fun stopBackend()

    /** One of "starting", "running", "failed: <message>", or "unavailable" if no .so. */
    override external fun status(): String
}
