import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Route ownership for the app-internal GlobalPlayerView (official id dk5).
///
/// Officially the view is added to each allowed Activity's content view, so
/// dialogs and sheets cover it while it stays attached underneath. Here one
/// [OverlayEntry] lives in the root Navigator's Overlay and is re-inserted
/// just above the topmost page route after every navigation change.
///
/// Only the root Navigator is observed: [configure] from a page inside a
/// nested Navigator has no effect.
class AudioFloatingRoutes extends NavigatorObserver with ChangeNotifier {
  AudioFloatingRoutes({this.defaultBottomInset = 0});

  /// Clearance above the bottom edge for pages that don't set their own.
  ///
  /// Official `getMainBottomHeight() + 18dp` applies on every allowed page,
  /// with or without a tab bar; the player adds the 18dp itself.
  final double defaultBottomInset;

  final _policies = <Route<dynamic>, ({bool hidden, double? bottomInset})>{};
  final _stack = <Route<dynamic>>[];
  OverlayEntry? _entry;
  OverlayState? _insertedIn;
  bool _placing = false;
  bool _notifying = false;
  bool _disposed = false;

  /// The topmost opaque page; popup routes above it don't move the player.
  Route<dynamic>? get _host {
    for (final route in _stack.reversed) {
      if (route is PageRoute && route.opaque) return route;
    }
    return null;
  }

  bool get visible {
    final host = _host;
    if (host is! PageRoute || !host.isActive) return false;
    if (_policies[host]?.hidden ?? false) return false;
    // A transparent page above the host covers it; dialogs and sheets don't.
    if (_stack.skip(_stack.indexOf(host) + 1).any((r) => r is PageRoute)) {
      return false;
    }
    return host.animation?.status == AnimationStatus.completed &&
        host.secondaryAnimation?.status == AnimationStatus.dismissed;
  }

  /// Whether the host is the app's first route (the home shell).
  bool get atRoot => _stack.isNotEmpty && identical(_host, _stack.first);

  double get bottomInset => _policies[_host]?.bottomInset ?? defaultBottomInset;

  void configure(
    Route<dynamic> route, {
    bool hidden = false,
    double? bottomInset,
  }) {
    if (!route.isActive) return;
    final policy = (hidden: hidden, bottomInset: bottomInset);
    if (_policies[route] == policy) return;
    _policies[route] = policy;
    if (identical(route, _host)) _changed();
  }

  /// Shows [builder] in the root Navigator's Overlay above the host page.
  void mount(WidgetBuilder builder) {
    assert(_entry == null, 'Only one floating player can be mounted.');
    _entry = OverlayEntry(builder: builder);
    _schedulePlacement();
  }

  void unmount() {
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    if (_insertedIn != null) entry.remove();
    _insertedIn = null;
    entry.dispose();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _listen(route, attach: true);
    _schedulePlacement();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _forget(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _forget(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    _policies.remove(oldRoute);
    _listen(oldRoute, attach: false);
    if (index >= 0) _stack.removeAt(index);
    if (newRoute != null) {
      _stack.insert(index >= 0 ? index : _stack.length, newRoute);
      _listen(newRoute, attach: true);
    }
    _schedulePlacement();
  }

  @override
  void didChangeTop(
    Route<dynamic> topRoute,
    Route<dynamic>? previousTopRoute,
  ) => _schedulePlacement();

  void _forget(Route<dynamic> route) {
    _stack.remove(route);
    _policies.remove(route);
    _listen(route, attach: false);
    _schedulePlacement();
  }

  // Every history flush rearranges the Overlay and leaves foreign entries on
  // top: after observer calls, and again when a push or pop animation ends
  // (`navigator.dart` `handlePush`/`finalizeRoute`). Both flushes run before
  // this microtask, so the entry is back in place within the same frame.
  void _schedulePlacement() {
    if (_placing || _disposed) return;
    _placing = true;
    scheduleMicrotask(_place);
  }

  void _place() {
    _placing = false;
    if (_disposed) return;
    final entry = _entry;
    final overlay = navigator?.overlay;
    if (entry != null && overlay != null && overlay.mounted) {
      final host = _host;
      final anchor = host is OverlayRoute && host.overlayEntries.isNotEmpty
          ? host.overlayEntries.last
          : null;
      if (_insertedIn != null) entry.remove();
      overlay.insert(entry, above: anchor);
      _insertedIn = overlay;
    }
    _changed();
  }

  void _listen(Route<dynamic>? route, {required bool attach}) {
    if (route is! TransitionRoute) return;
    for (final animation in [route.animation, route.secondaryAnimation]) {
      if (attach) {
        animation?.addStatusListener(_animationChanged);
      } else {
        animation?.removeStatusListener(_animationChanged);
      }
    }
  }

  void _animationChanged(AnimationStatus _) => _schedulePlacement();

  void _changed() {
    if (_disposed) return;
    // Pages configure their policy while building; listeners rebuild after.
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifying) return;
    _notifying = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifying = false;
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    unmount();
    for (final route in _stack) {
      _listen(route, attach: false);
    }
    _stack.clear();
    _policies.clear();
    super.dispose();
  }
}

class AudioFloatingRouteScope extends InheritedNotifier<AudioFloatingRoutes> {
  const AudioFloatingRouteScope({
    super.key,
    required AudioFloatingRoutes routes,
    required super.child,
  }) : super(notifier: routes);

  /// Reads the routes without rebuilding the caller when they change.
  static AudioFloatingRoutes? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<AudioFloatingRouteScope>()
      ?.notifier;

  static void configure(
    BuildContext context, {
    bool hidden = false,
    double? bottomInset,
  }) {
    final routes = read(context);
    final route = ModalRoute.of(context);
    if (routes == null || route == null) return;
    routes.configure(route, hidden: hidden, bottomInset: bottomInset);
  }
}
