import 'dart:async';

import 'package:flutter/services.dart';

import 'platform_channel.dart';

/// System bars for the fullscreen video player.
///
/// Android 15+ enforces edge-to-edge for target SDK 35+, where Flutter's
/// [SystemUiMode.immersiveSticky] only sets legacy system UI visibility flags
/// and no longer hides the bars (issue #176). The Android host hides them
/// through `WindowInsetsController` on the `fqapp/player_system_ui` channel;
/// hosts without that bridge (Windows, tests) keep the [SystemChrome] fallback.
class PlayerSystemUi {
  const PlayerSystemUi._();

  static const _channel = AppMethodChannel('fqapp/player_system_ui');

  /// Requests a hide without awaiting the platform reply.
  ///
  /// A toggle also changes the orientation right after this call; waiting here
  /// would let a host that never answers the channel stall the orientation
  /// request (which happens in widget tests, where unhandled channels never
  /// reply). Message order is still preserved, so a later [show] lands after
  /// this hide.
  static Future<void> hide() async {
    try {
      unawaited(
        _channel.invokeMethod<void>('hide').catchError((Object error) async {
          if (error is MissingPluginException || error is PlatformException) {
            await _legacyHide();
          }
        }),
      );
    } catch (_) {
      await _legacyHide();
    }
  }

  static Future<void> show() async {
    try {
      unawaited(
        _channel.invokeMethod<void>('show').catchError((Object error) async {}),
      );
    } catch (_) {}
    // Keep the engine's own mode aligned with the restored native state.
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
  }

  static Future<void> _legacyHide() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
  }
}
