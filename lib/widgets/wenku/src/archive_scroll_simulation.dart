// Ported from Wenku8_Flutter lib/archive_scroll_simulation.dart
// (revision ebcd7f1). Verbatim copy; no substitutions.

import 'dart:math' as math;

import 'package:flutter/physics.dart';

/// Momentum first, a book detent last. Both phases share position and velocity,
/// so release never turns into a new canned centering animation.
class ArchiveScrollSimulation extends Simulation {
  ArchiveScrollSimulation({
    required double position,
    required double velocity,
    required double pitch,
    double minimumVelocity = 50,
    super.tolerance,
  }) : assert(pitch > 0) {
    final speed = velocity.abs();
    final directional = speed >= minimumVelocity;
    final release = directional ? velocity : 0.0;
    var destination =
        ((position + release / _dragRate) / pitch).round() * pitch;
    // A genuine flick should land ahead, not coast past its destination then
    // reverse. Keep enough runway for a monotonic, progressively slowing tail.
    if (directional &&
        (destination - position) * release.sign < speed / _omega) {
      final runway = position + release / _omega;
      destination =
          (release > 0 ? (runway / pitch).ceil() : (runway / pitch).floor()) *
          pitch;
    }
    target = destination;
    final handoffSpeed = pitch * 4;
    coastDuration = speed > handoffSpeed && directional
        ? math.log(speed / handoffSpeed) / _dragRate
        : 0;
    _coast = FrictionSimulation(math.exp(-_dragRate), position, release);
    _handoffPosition = _coast.x(coastDuration);
    _handoffVelocity = _coast.dx(coastDuration);
    _landingDuration = directional
        ? 3 * (target - _handoffPosition) / _handoffVelocity
        : 0;
    _restDetent = SpringSimulation(
      const SpringDescription(
        mass: 1,
        stiffness: _omega * _omega,
        damping: 2 * _omega,
      ),
      position,
      target,
      0,
      // Exact integer lanes without leaving an almost-centered idle cover.
      snapToEnd: true,
      tolerance: Tolerance(
        distance: math.min(tolerance.distance, .01),
        velocity: math.min(tolerance.velocity, .1),
      ),
    );
  }

  static const _dragRate = 4.4;
  static const _omega = 12.0;
  late final double target;
  late final double coastDuration;
  late final FrictionSimulation _coast;
  late final double _handoffPosition, _handoffVelocity, _landingDuration;
  late final SpringSimulation _restDetent;

  double _remaining(double time) =>
      (1 - (time - coastDuration) / _landingDuration).clamp(0.0, 1.0);

  @override
  double x(double time) {
    if (_landingDuration == 0) return _restDetent.x(time);
    if (time < coastDuration) return _coast.x(time);
    // The finite cubic landing has the incoming velocity at its start and
    // zero velocity/acceleration at the exact lane. No spring back or overshoot.
    final remaining = _remaining(time);
    return target -
        (target - _handoffPosition) * remaining * remaining * remaining;
  }

  @override
  double dx(double time) {
    if (_landingDuration == 0) return _restDetent.dx(time);
    if (time < coastDuration) return _coast.dx(time);
    final remaining = _remaining(time);
    return _handoffVelocity * remaining * remaining;
  }

  @override
  bool isDone(double time) => _landingDuration == 0
      ? _restDetent.isDone(time)
      : time >= coastDuration + _landingDuration;
}
