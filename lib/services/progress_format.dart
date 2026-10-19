/// Formats a 0..1 reading progress fraction for compact UI labels.
///
/// Rounding a genuinely started book down to `0%` makes the shelf and home
/// continuation card look as if nothing was read. Keep the truthful `<1%`
/// marker for positive values that round below one percent.
String formatProgressPercent(double progress) {
  final value = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  if (value <= 0) return '0%';
  final percent = (value * 100).round();
  return percent == 0 ? '<1%' : '$percent%';
}
