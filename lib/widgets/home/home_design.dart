import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../services/app_theme.dart';

/// Shared design tokens for the home surface and the surrounding destinations.
///
/// The palette intentionally follows the app's warm paper / coral identity
/// instead of introducing a second, competing accent. Keep colour and spacing
/// decisions here so a future refresh does not start another one-off system.
class HomePalette {
  static const accent = Color(0xFFEF5038);
  static const accentStrong = Color(0xFFC73D29);

  final bool dark;

  /// E-ink mode collapses paper, text and rules to pure black and white.
  final bool eink;

  const HomePalette(this.dark, {this.eink = false});

  factory HomePalette.of(BuildContext context) => HomePalette(
    Theme.of(context).brightness == Brightness.dark,
    eink: einkModeNotifier.value,
  );

  Color get canvas => eink
      ? Colors.white
      : (dark ? const Color(0xFF151517) : const Color(0xFFFCFAF7));
  Color get surface =>
      eink ? Colors.white : (dark ? const Color(0xFF242427) : Colors.white);
  Color get ink => eink
      ? Colors.black
      : (dark ? const Color(0xFFF5F1EB) : const Color(0xFF262522));
  Color get muted => eink
      ? Colors.black
      : (dark ? const Color(0xFFA7A39E) : const Color(0xFF706C66));
  Color get accentText => eink ? Colors.black : (dark ? accent : accentStrong);
  Color get soft => eink
      ? Colors.white
      : (dark ? const Color(0xFF202023) : const Color(0xFFF4F0EB));
  Color get line => eink
      ? Colors.black
      : (dark ? const Color(0xFF333336) : const Color(0xFFE8E4DE));

  /// A lighter rule for internal rhythm; it should never compete with content.
  Color get hairline => eink
      ? Colors.black
      : (dark ? const Color(0xFF2A2A2D) : const Color(0xFFF0ECE6));

  // Semantic aliases used by newer components.
  Color get primary => ink;
  Color get secondary => muted;
  Color get tertiary => eink
      ? Colors.black54
      : (dark ? const Color(0xFF77736E) : const Color(0xFF9A958D));
  Color get divider => line;

  /// Low-contrast fill for search fields and quiet utility buttons.
  Color get chipBg => soft;
}

/// A single, restrained elevation level for floating utility surfaces.
class HomeShadow {
  const HomeShadow._();

  static List<BoxShadow> soft(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.20 : 0.025),
      blurRadius: 14,
      offset: const Offset(0, 5),
    ),
  ];
}

/// Vertical rhythm and page gutters.
class HomeSpace {
  const HomeSpace._();

  /// Page gutter shared by the masthead, section headings and card grid.
  static const gutter = 16.0;

  /// Space between independent sections.
  static const section = 24.0;

  /// Space between a section heading and its content.
  static const heading = 12.0;

  /// Space between closely related lines.
  static const row = 8.0;
}

/// Typography ladder.
///
/// Hierarchy comes from scale, weight and whitespace — not from extra labels,
/// numbering systems or decorative chrome.
class HomeType {
  const HomeType._();

  /// Masthead statement. The only display-size type on the home page.
  static const display = TextStyle(
    fontSize: 32,
    height: 1.14,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.9,
  );

  /// Section title.
  static const section = TextStyle(
    fontSize: 20,
    height: 1.28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.35,
  );

  /// Small kicker above a title.
  static const eyebrow = TextStyle(
    fontSize: 10.5,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
  );

  /// Card title line height, shared with the measured grid budget.
  static const cardLineHeight = 1.45;

  static const card = TextStyle(
    fontSize: 15,
    height: cardLineHeight,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  /// Metadata line height, also used by the measured grid budget.
  static const metaLineHeight = 1.4;

  static const meta = TextStyle(
    fontSize: 12,
    height: metaLineHeight,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );

  /// Tabular figures for counters and ratings.
  static const figure = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Quiet semantic marks for the five content types.
class HomeKindTint {
  const HomeKindTint._();

  static const book = Color(0xFF6A7964);
  static const video = Color(0xFF9C5744);
  static const manju = Color(0xFF8B557E);
  static const manga = Color(0xFF6F6887);
  static const audio = Color(0xFF426C78);

  static Color of(String kind, {bool eink = false}) {
    if (eink) return Colors.black;
    return switch (kind) {
      'video' || '短剧' => video,
      'manju' || '漫剧' => manju,
      'manga' || '漫画' => manga,
      'audio' || '听书' => audio,
      _ => book,
    };
  }
}

/// Pointer, keyboard and accessibility activation share one spring action.
///
/// No idle animation is scheduled; the controller settles immediately after a
/// press and is disposed with the widget.
class HomePressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final String? semanticLabel;
  final double pressedScale;

  const HomePressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.semanticLabel,
    this.pressedScale = 0.972,
  });

  @override
  State<HomePressable> createState() => _HomePressableState();
}

class _HomePressableState extends State<HomePressable>
    with SingleTickerProviderStateMixin {
  late final _scale = AnimationController.unbounded(vsync: this, value: 1);

  void _press(bool pressed) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _scale.stop();
      _scale.value = 1;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 480, damping: 30),
        _scale.value,
        pressed ? widget.pressedScale : 1,
        0,
      ),
    );
  }

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _scale,
    builder: (context, child) =>
        Transform.scale(scale: _scale.value, child: child),
    child: Semantics(
      label: widget.semanticLabel,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onTapDown: (_) => _press(true),
          onTapUp: (_) => _press(false),
          onTapCancel: () => _press(false),
          borderRadius: widget.borderRadius,
          splashColor: HomePalette.accent.withValues(alpha: 0.07),
          highlightColor: Colors.transparent,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// A one-shot fade-and-lift used for content that enters after load.
class HomeEntrance extends StatelessWidget {
  final int index;
  final bool animate;
  final Widget child;

  const HomeEntrance({
    super.key,
    this.index = 0,
    this.animate = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 360 + index.clamp(0, 5) * 36),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: 0.4 + value * 0.6,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - value)),
          child: child,
        ),
      ),
    );
  }
}

/// Section heading with a small coral rule, one title and an optional action.
///
/// The former numeric index has been removed from the visual language: it made
/// a vertically scrolling feed look like a table of contents. The parameter is
/// kept for source compatibility and intentionally ignored.
class HomeSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? index;
  final Widget? trailing;

  const HomeSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.index,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    final accent = palette.eink ? Colors.black : HomePalette.accent;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeSpace.gutter,
        HomeSpace.section,
        HomeSpace.gutter,
        HomeSpace.heading,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textScaler: scaler,
                  style: HomeType.section.copyWith(color: palette.primary),
                ),
                if (subtitle case final text? when text.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: scaler,
                    style: HomeType.meta.copyWith(color: palette.secondary),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
