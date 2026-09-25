package com.fqapp.fqapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer host for DRM short dramas (CENC streaming decrypt).
        flutterEngine.plugins.add(NativePlayerPlugin())
        flutterEngine.plugins.add(ReaderDevicePlugin())
        // 官方系统分享是 Intent.ACTION_SEND；没有可分享的应用时回 false。
        flutterEngine.plugins.add(SharePlugin())
    }
}
