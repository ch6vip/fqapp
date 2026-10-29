package com.fqapp.fqapp

import android.os.Build
import android.view.ViewTreeObserver
import android.view.WindowManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Note: fullscreen video hides the system bars through WindowInsetsController;
// see PlayerSystemBarsSession for why SystemUiMode.immersiveSticky no longer
// works once target SDK 35+ enforces edge-to-edge.
class PlayerSystemUiPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var methods: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private val systemBars = PlayerSystemBarsSession()
    private val windowFocusListener = ViewTreeObserver.OnWindowFocusChangeListener { focused ->
        // The OS can restore the bars on focus gain (resume, transient swipe,
        // returning from another app); re-hide while fullscreen is still open.
        if (focused) systemBars.reapply()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "fqapp/player_system_ui")
        methods.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        systemBars.clear()
        methods.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        val window = binding.activity.window
        val decor = window.decorView
        val controller = WindowCompat.getInsetsController(window, decor)
        val types = WindowInsetsCompat.Type.systemBars()
        systemBars.attach(object : PlayerSystemBarsSession.Window {
            override fun snapshot(): PlayerSystemBarsSession.State {
                val insets = ViewCompat.getRootWindowInsets(decor)
                var visible = 0
                for (type in listOf(
                    WindowInsetsCompat.Type.statusBars(),
                    WindowInsetsCompat.Type.navigationBars(),
                    WindowInsetsCompat.Type.captionBar(),
                )) {
                    if (insets == null || insets.isVisible(type)) visible = visible or type
                }
                return PlayerSystemBarsSession.State(
                    visible,
                    controller.systemBarsBehavior,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        window.attributes.layoutInDisplayCutoutMode
                    } else null,
                )
            }

            override fun hide() {
                // DEFAULT can letterbox the window when the status bar hides;
                // extend it like the reader does and let Flutter handle content
                // insets.
                setCutoutMode(
                    when {
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                        else -> null
                    }
                )
                controller.systemBarsBehavior =
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(types)
            }

            override fun restore(state: PlayerSystemBarsSession.State) {
                setCutoutMode(state.cutoutMode)
                controller.systemBarsBehavior = state.behavior
                controller.show(state.visibleTypes)
                controller.hide(types and state.visibleTypes.inv())
            }

            private fun setCutoutMode(mode: Int?) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P || mode == null) return
                val attributes = window.attributes
                if (attributes.layoutInDisplayCutoutMode == mode) return
                attributes.layoutInDisplayCutoutMode = mode
                window.attributes = attributes
            }
        })
        decor.viewTreeObserver.addOnWindowFocusChangeListener(windowFocusListener)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.activity?.window?.decorView?.viewTreeObserver
            ?.removeOnWindowFocusChangeListener(windowFocusListener)
        // Keep the hidden flag: a rotation recreates the activity and the
        // player is still fullscreen, so attach() re-applies the hide.
        systemBars.detach()
        binding = null
    }

    override fun onDetachedFromActivity() {
        systemBars.clear()
        onDetachedFromActivityForConfigChanges()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hide" -> {
                systemBars.hide()
                result.success(null)
            }
            "show" -> {
                systemBars.show()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
