import 'package:flutter/material.dart';

/// Route ownership for the app-internal GlobalPlayerView (official id dk5).
class AudioFloatingRoutes extends NavigatorObserver with ChangeNotifier {
  final _policies = <Route<dynamic>, ({bool hidden, double bottomInset})>{};
  Route<dynamic>? _top;
  bool _pending = false;
  bool _disposed = false;

  bool get visible {
    final top = _top;
    return top is PageRoute &&
        top.isCurrent &&
        top.opaque &&
        !top.fullscreenDialog &&
        !(_policies[top]?.hidden ?? false) &&
        top.animation?.status == AnimationStatus.completed &&
        top.secondaryAnimation?.status == AnimationStatus.dismissed;
  }

  double get bottomInset => _policies[_top]?.bottomInset ?? 0;

  void configure(
    Route<dynamic> route, {
    bool hidden = false,
    double bottomInset = 0,
  }) {
    if (!route.isActive) return;
    final policy = (hidden: hidden, bottomInset: bottomInset);
    if (_policies[route] == policy) return;
    _policies[route] = policy;
    if (identical(route, _top)) _changed();
  }

  void _animationChanged(AnimationStatus _) => _changed();

  void _watch(Route<dynamic>? route, {required bool attach}) {
    if (route is! TransitionRoute) return;
    for (final animation in [route.animation, route.secondaryAnimation]) {
      if (attach) {
        animation?.addStatusListener(_animationChanged);
      } else {
        animation?.removeStatusListener(_animationChanged);
      }
    }
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _watch(_top, attach: false);
    _top = topRoute;
    _watch(_top, attach: true);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _policies.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _policies.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _policies.remove(oldRoute);
  }

  void _changed() {
    if (_pending || _disposed) return;
    _pending = true;
    // Page policies can change during Navigator builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _watch(_top, attach: false);
    _top = null;
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

  static AudioFloatingRoutes? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AudioFloatingRouteScope>()
      ?.notifier;

  static void configure(
    BuildContext context, {
    bool hidden = false,
    double bottomInset = 0,
  }) {
    final routes = context
        .getInheritedWidgetOfExactType<AudioFloatingRouteScope>()
        ?.notifier;
    final route = ModalRoute.of(context);
    if (routes == null || route == null) return;
    routes.configure(route, hidden: hidden, bottomInset: bottomInset);
  }
}
