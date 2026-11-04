import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Coast first, then land on a rank without reversing or crossing its bounds.
class HomeRankScrollPhysics extends ScrollPhysics {
  const HomeRankScrollPhysics({
    required this.pitchFor,
    super.parent = const ClampingScrollPhysics(),
  });

  // Scrollable can retain its physics across resizes; use the live viewport.
  final double Function(double width) pitchFor;

  @override
  HomeRankScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      HomeRankScrollPhysics(pitchFor: pitchFor, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (!position.hasContentDimensions) return null;
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final pitch = pitchFor(position.viewportDimension);
    assert(pitch > 0);
    final simulation = _RankScrollSimulation(
      position: position.pixels,
      velocity: velocity,
      pitch: pitch,
      minimum: position.minScrollExtent,
      maximum: position.maxScrollExtent,
      minimumVelocity: minFlingVelocity,
      tolerance: toleranceFor(position),
    );
    if ((simulation.target - position.pixels).abs() < .01) return null;
    return simulation;
  }
}

// Coast/landing model adapted from mikufoxxx/Wenku8_Flutter, ebcd7f1
// (lib/archive_scroll_simulation.dart, GPL-3.0), with finite rank boundaries.
class _RankScrollSimulation extends Simulation {
  _RankScrollSimulation({
    required double position,
    required double velocity,
    required double pitch,
    required double minimum,
    required double maximum,
    required double minimumVelocity,
    required super.tolerance,
  }) {
    final speed = velocity.abs();
    final release = speed >= minimumVelocity ? velocity : 0.0;
    var destination =
        ((position + release / _dragRate) / pitch).round() * pitch;
    if (release != 0 &&
        (destination - position) * release.sign < speed / _omega) {
      final runway = (position + release / _omega) / pitch;
      destination = (release > 0 ? runway.ceil() : runway.floor()) * pitch;
    }
    target = destination.clamp(minimum, maximum);
    _rest = SpringSimulation(
      const SpringDescription(
        mass: 1,
        stiffness: _omega * _omega,
        damping: 2 * _omega,
      ),
      position,
      target,
      0,
      snapToEnd: true,
      tolerance: Tolerance(
        distance: math.min(tolerance.distance, .01),
        velocity: math.min(tolerance.velocity, .1),
      ),
    );
    _coast = FrictionSimulation(math.exp(-_dragRate), position, release);
    final handoffSpeed = pitch * 4;
    var coastDuration = release != 0 && speed > handoffSpeed
        ? math.log(speed / handoffSpeed) / _dragRate
        : 0.0;
    if (target != destination && release != 0) {
      // Unlike an infinite shelf, an edge needs room left for braking.
      final fraction = (target - position).abs() * .7 * _dragRate / speed;
      if (fraction < 1) {
        coastDuration = math.min(
          coastDuration,
          -math.log(1 - fraction) / _dragRate,
        );
      }
    }
    _coastDuration = coastDuration;
    _handoffPosition = _coast.x(_coastDuration);
    _handoffVelocity = _coast.dx(_coastDuration);
    _landingDuration = release == 0
        ? 0
        : 3 * (target - _handoffPosition) / _handoffVelocity;
  }

  static const _dragRate = 4.4;
  static const _omega = 12.0;
  late final double target;
  late final FrictionSimulation _coast;
  late final SpringSimulation _rest;
  late final double _handoffPosition, _handoffVelocity, _landingDuration;
  late final double _coastDuration;

  double _remaining(double time) =>
      (1 - (time - _coastDuration) / _landingDuration).clamp(0.0, 1.0);

  @override
  double x(double time) {
    if (_landingDuration <= 0) return _rest.x(time);
    if (time < _coastDuration) return _coast.x(time);
    final remaining = _remaining(time);
    return target -
        (target - _handoffPosition) * remaining * remaining * remaining;
  }

  @override
  double dx(double time) {
    if (_landingDuration <= 0) return _rest.dx(time);
    if (time < _coastDuration) return _coast.dx(time);
    final remaining = _remaining(time);
    return _handoffVelocity * remaining * remaining;
  }

  @override
  bool isDone(double time) => _landingDuration <= 0
      ? _rest.isDone(time)
      : time >= _coastDuration + _landingDuration;
}
