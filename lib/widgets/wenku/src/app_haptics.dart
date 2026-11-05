import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Interaction cues retain the upstream meaning; fqapp uses Flutter's native
/// presets instead of importing the upstream persisted haptic settings.
enum HapticCue {
  selection,
  shelfStep,
  detent,
  pageTurn,
  action,
  longPress,
  boundary,
  success,
  warning,
  error,
}

class HapticGate {
  Duration? _last;
  final _lastForCue = <HapticCue, Duration>{};

  static Duration interval(HapticCue cue) => Duration(
    milliseconds: switch (cue) {
      HapticCue.shelfStep => 65,
      HapticCue.detent => 70,
      HapticCue.selection => 80,
      HapticCue.pageTurn => 110,
      HapticCue.action => 100,
      HapticCue.longPress => 150,
      HapticCue.boundary => 100,
      HapticCue.success => 350,
      HapticCue.warning => 400,
      HapticCue.error => 450,
    },
  );

  bool accept(HapticCue cue, Duration now) {
    if (_last case final last?) {
      if (now - last < const Duration(milliseconds: 65)) return false;
    }
    if (_lastForCue[cue] case final previous?) {
      if (now - previous < interval(cue)) return false;
    }
    _last = now;
    _lastForCue[cue] = now;
    return true;
  }
}

abstract final class AppHaptics {
  static final _clock = Stopwatch()..start();
  static final _gate = HapticGate();

  static void play(BuildContext context, HapticCue? cue) {
    if (cue == null || !context.mounted || kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (!TickerMode.getValuesNotifier(context).value.enabled) return;
    if (!_gate.accept(cue, _clock.elapsed)) return;
    unawaited(_send(cue));
  }

  static Future<void> _send(HapticCue cue) async {
    try {
      await switch (cue) {
        HapticCue.selection ||
        HapticCue.shelfStep ||
        HapticCue.detent ||
        HapticCue.pageTurn ||
        HapticCue.action => HapticFeedback.selectionClick(),
        HapticCue.longPress => HapticFeedback.mediumImpact(),
        HapticCue.boundary => HapticFeedback.lightImpact(),
        HapticCue.success => HapticFeedback.mediumImpact(),
        HapticCue.warning || HapticCue.error => HapticFeedback.mediumImpact(),
      };
    } on PlatformException {
      // Optional tactile feedback never interrupts the accepted action.
    }
  }
}
