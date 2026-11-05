import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart' as easy;

import 'src/app_haptics.dart';
import 'src/app_text.dart';
import 'src/dock_layout.dart';
import 'src/easy_glass.dart';
import 'src/glass_optics.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_icons.dart';
import 'wenku_theme.dart';

export 'src/app_haptics.dart';

/// Live appearance values are shared by controls, navigation and scroll edges.
class GlassAppearance extends InheritedWidget {
  const GlassAppearance({
    super.key,
    required super.child,
    this.blur = 8,
    this.opacity = .87,
  });

  final double blur;
  final double opacity;

  static GlassAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassAppearance>() ??
      const GlassAppearance(child: SizedBox.shrink());

  static Color tintOf(BuildContext context, {required double opacity}) =>
      Theme.of(context).extension<WenkuTonalColors>()?.tint(
        Theme.of(context).brightness,
        opacity,
      ) ??
      ArchiveDesign.glassTint(Theme.of(context).brightness, opacity: opacity);

  @override
  bool updateShouldNotify(GlassAppearance oldWidget) =>
      blur != oldWidget.blur || opacity != oldWidget.opacity;
}

class Atmosphere extends StatelessWidget {
  const Atmosphere({
    super.key,
    required this.child,
    this.headerBackground,
    this.shareGlass = false,
    this.archiveBackdrop = true,
  });

  final Widget child;
  final Widget? headerBackground;
  final bool shareGlass;
  final bool archiveBackdrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tonal = theme.extension<WenkuTonalColors>();
    final appearance = WenkuTheme.appearanceOf(context);
    final plain = appearance.eink || MediaQuery.highContrastOf(context);
    final content = headerBackground == null
        ? child
        : Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(child: headerBackground),
                ),
              ),
              child,
            ],
          );
    final background = archiveBackdrop && !plain
        ? Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: ArchiveBackdrop(
                  filmColor: tonal?.milk ?? theme.colorScheme.surface,
                ),
              ),
              content,
            ],
          )
        : content;
    final grouped = easy.LiquidGlassScrollEdgeGroup(
      enabled: !plain && PerformanceScope.of(context).edgeBlur,
      child: shareGlass && PerformanceScope.of(context).glass
          ? easy.LiquidGlassBatch(child: background)
          : background,
    );
    if (plain) {
      return ColoredBox(color: theme.colorScheme.surface, child: grouped);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tonal != null
              ? [tonal.pageStart, tonal.pageEnd]
              : [theme.scaffoldBackgroundColor, theme.scaffoldBackgroundColor],
        ),
      ),
      child: grouped,
    );
  }
}

/// Route titles are centered on the navigation plane, not on the space left
/// over after the back button. Both sides reserve the wider control group.
class ArchiveHeaderBar extends StatelessWidget {
  const ArchiveHeaderBar({
    super.key,
    required this.title,
    required this.leading,
    this.actions = const [],
  });

  final Widget title;
  final Widget leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: CustomMultiChildLayout(
      delegate: _ArchiveHeaderLayout(),
      children: [
        LayoutId(id: 'leading', child: leading),
        LayoutId(id: 'title', child: title),
        LayoutId(
          id: 'actions',
          child: Row(mainAxisSize: MainAxisSize.min, children: actions),
        ),
      ],
    ),
  );
}

class _ArchiveHeaderLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final sideConstraints = BoxConstraints(
      maxWidth: size.width / 2,
      maxHeight: size.height,
    );
    final leading = layoutChild('leading', sideConstraints);
    final actions = layoutChild('actions', sideConstraints);
    positionChild('leading', Offset(0, (size.height - leading.height) / 2));
    positionChild(
      'actions',
      Offset(size.width - actions.width, (size.height - actions.height) / 2),
    );
    final gutter = math.max(leading.width, actions.width) + 8;
    final title = layoutChild(
      'title',
      BoxConstraints(
        maxWidth: math.max(0, size.width - gutter * 2),
        maxHeight: size.height,
      ),
    );
    positionChild(
      'title',
      Offset((size.width - title.width) / 2, (size.height - title.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_ArchiveHeaderLayout oldDelegate) => false;
}

/// Content may bounce under this header; its controls never join the scroll
/// viewport's transform or stretching overscroll layer.
class FrostedHeader extends StatelessWidget {
  const FrostedHeader({
    super.key,
    required this.child,
    this.blurBackground = true,
    this.extraHeight = 0,
  });

  static const toolbarHeight = 56.0;
  static const featherHeight = 56.0;
  final Widget child;
  final bool blurBackground;
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final statusHeight = math.max(
      padding.top,
      MediaQuery.viewPaddingOf(context).top,
    );
    final appearance = GlassAppearance.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final eink = WenkuTheme.isEinkOf(context);
    final performance = PerformanceScope.of(context);
    // The black edge falloff is upstream chrome, not part of the blur pass.
    final showShade =
        blurBackground && !highContrast && !eink && appearance.blur > 0;
    final showBlur = showShade && performance.edgeBlur;
    return SizedBox(
      key: const ValueKey('frosted-navigation-plane'),
      height:
          statusHeight +
          toolbarHeight +
          extraHeight +
          (highContrast || eink ? 0 : featherHeight),
      child: Stack(
        children: [
          if (showShade)
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    fit: StackFit.expand,
                    children: [
                      if (showBlur)
                        EasyScrollEdge(
                          blur: appearance.blur,
                          plateau: statusHeight,
                          fromBottom: false,
                          child: const SizedBox.expand(),
                        ),
                      if (DockLayout.topEdgeShadeOpacity > 0)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withValues(
                                  alpha: DockLayout.topEdgeShadeOpacity,
                                ),
                                Colors.black.withValues(
                                  alpha: DockLayout.topEdgeShadeOpacity,
                                ),
                                Colors.transparent,
                              ],
                              stops: [
                                0,
                                (statusHeight / constraints.maxHeight).clamp(
                                  0.0,
                                  1.0,
                                ),
                                1,
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (highContrast || eink)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              ),
            ),
          Positioned(
            top: statusHeight,
            left: padding.left + 24,
            right: padding.right + 24,
            height: toolbarHeight + extraHeight,
            child: easy.LiquidGlassBatch(child: GlassForeground(child: child)),
          ),
        ],
      ),
    );
  }
}

/// Reusable pinned navigation plane. The blur paints after the scrollable,
/// while its feather is pointer-transparent and never covers a button's hitbox.
class GlassHeaderLayout extends StatelessWidget {
  const GlassHeaderLayout({
    super.key,
    required this.body,
    required this.header,
    this.showHeader = true,
    this.extraHeight = 0,
  });

  final Widget body;
  final Widget header;
  final bool showHeader;
  final double extraHeight;

  @override
  Widget build(BuildContext context) => !showHeader
      ? body
      : Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: FrostedHeader(extraHeight: extraHeight, child: header),
            ),
          ],
        );
}

class WenkuPage extends StatelessWidget {
  const WenkuPage({
    super.key,
    required this.child,
    this.header,
    this.showHeader = true,
    this.archiveBackdrop = true,
    this.resizeToAvoidBottomInset = true,
    this.extraHeight = 0,
  });

  final Widget child;
  final Widget? header;
  final bool showHeader;
  final bool archiveBackdrop;
  final bool resizeToAvoidBottomInset;
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    if (WenkuScope.isActive(context)) return _buildPage(context);
    return WenkuScope(child: Builder(builder: _buildPage));
  }

  Widget _buildPage(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    backgroundColor: Colors.transparent,
    body: Atmosphere(
      archiveBackdrop: archiveBackdrop,
      child: GlassHeaderLayout(
        showHeader: showHeader && header != null,
        header: header ?? const SizedBox.shrink(),
        body: child,
        extraHeight: extraHeight,
      ),
    ),
  );
}

/// Foreground stays crisp; the glass material itself carries the emission.
class GlassForeground extends StatelessWidget {
  const GlassForeground({super.key, required this.child});
  final Widget child;

  static List<Shadow> shadowsOf(BuildContext context) => const [];

  @override
  Widget build(BuildContext context) => child;
}

/// Navigation typography uses the same crisp foreground as glass controls.
class GlassText extends StatelessWidget {
  const GlassText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => AppText(
    data,
    maxLines: maxLines,
    overflow: overflow,
    textAlign: textAlign,
    style: (style ?? const TextStyle()).copyWith(
      shadows: GlassForeground.shadowsOf(context),
    ),
  );
}

class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.radius = 28,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.haptic = HapticCue.action,
    this.semanticLabel,
    this.elevated = false,
    this.thickness = 20,
    this.blur,
    this.tintColor,
    this.tintOpacity,
    this.activation = 0,
    this.touchPosition = .5,
    this.shadowStrength = 1,
    this.preserveOptics = false,
    this.transparent = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final HapticCue? haptic;
  final String? semanticLabel;
  final bool elevated;
  final double thickness;
  final double? blur;
  final Color? tintColor;
  final double? tintOpacity;
  final double activation;
  final double touchPosition;
  final double shadowStrength;
  final bool preserveOptics;
  final bool transparent;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _pressed = false;
  bool _cancelledPress = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final appearance = GlassAppearance.of(context);
    final settings = PerformanceScope.of(context);
    final highContrast = media.highContrast;
    final eink = WenkuTheme.isEinkOf(context);
    final opaque =
        !widget.transparent && (highContrast || eink || !settings.glass);
    final surface = Theme.of(context).colorScheme.surface;
    final tintOpacity = widget.tintOpacity ?? appearance.opacity;
    final tint =
        widget.tintColor ??
        GlassAppearance.tintOf(context, opacity: tintOpacity);
    final interaction = Material(
      color: Colors.transparent,
      child: Semantics(
        button: widget.onTap != null,
        label: widget.semanticLabel,
        child: InkWell(
          enableFeedback: false,
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.play(context, widget.haptic);
                  setState(() => _iconActivation++);
                  widget.onTap!();
                },
          onTapCancel: widget.onTap == null
              ? null
              : () => setState(() => _cancelledPress = true),
          onHighlightChanged: widget.onTap == null
              ? null
              : (pressed) => setState(() {
                  _pressed = pressed;
                  if (pressed) _cancelledPress = false;
                }),
          splashFactory: NoSplash.splashFactory,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: Padding(
            padding: widget.padding,
            child: ArchiveIconContact(
              pressed: _pressed,
              activation: _iconActivation,
              child: GlassForeground(child: widget.child),
            ),
          ),
        ),
      ),
    );
    final Widget material;
    if (widget.transparent) {
      material = interaction;
    } else if (opaque) {
      material = Material(
        color: highContrast || eink
            ? surface
            : tint.withValues(alpha: tintOpacity),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.radius),
          side: highContrast || eink
              ? BorderSide(color: Theme.of(context).colorScheme.outline)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: interaction,
      );
    } else {
      material = EasyGlassSurface(
        radius: widget.radius,
        thickness: widget.thickness,
        blur: widget.blur ?? 0,
        refractiveIndex: GlassOptics.refractiveIndex,
        tint: tint.withValues(alpha: tintOpacity),
        emission:
            (dark ? .024 : .010) *
            (1 + .12 * math.max(widget.activation, _pressed ? 1 : 0)),
        activation: widget.activation,
        physicalOptics: widget.preserveOptics,
        child: interaction,
      );
    }
    return AnimatedScale(
      scale: _pressed && !media.disableAnimations ? .97 : 1,
      duration: media.disableAnimations || _cancelledPress
          ? Duration.zero
          : _pressed
          ? WenkuMotion.contact
          : WenkuMotion.enter,
      curve: WenkuMotion.settle,
      child: material,
    );
  }
}

/// A compact icon action with the shared hit area, semantics and app haptic.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : child = null;

  const GlassIconButton.custom({
    super.key,
    required this.child,
    required this.label,
    required this.onPressed,
    this.haptic = HapticCue.action,
    this.liveGlass = true,
    this.transparent = false,
    this.pageHeight,
    this.compactMainPage = false,
  }) : icon = null,
       color = null;

  final IconData? icon;
  final Widget? child;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final HapticCue? haptic;
  final bool liveGlass;
  final bool transparent;
  final double? pageHeight;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final compact = compactMainPage;
    final geometry = _compactControlGeometry(context);
    final size = compact ? Size(48, geometry.hit) : const Size.square(46);
    final content = SizedBox(
      width: size.width,
      height: size.height,
      child: _unscaleCompactContent(
        compact: compact,
        scaleX: 40 / 48,
        scaleY: geometry.scale,
        child:
            child ??
            ArchiveIcon(
              icon,
              size: compact ? 20 : 21,
              color:
                  color ??
                  (onPressed == null ? Theme.of(context).disabledColor : null),
            ),
      ),
    );
    final semanticLabel = appText(context, label);
    final action = Semantics(
      button: true,
      enabled: onPressed != null,
      child: Tooltip(
        message: semanticLabel,
        triggerMode: TooltipTriggerMode.manual,
        excludeFromSemantics: true,
        child: _scaleCompactFace(
          compact: compact,
          scaleX: 40 / 48,
          scaleY: geometry.scale,
          child: liveGlass
              ? LiquidGlass(
                  radius: 24,
                  elevated: false,
                  semanticLabel: semanticLabel,
                  onTap: onPressed,
                  haptic: haptic,
                  child: content,
                )
              : _PaintedIconAction(
                  size: size,
                  transparent: transparent,
                  label: semanticLabel,
                  onPressed: onPressed,
                  haptic: haptic,
                  child: content,
                ),
        ),
      ),
    );
    return liveGlass ? action : MergeSemantics(child: action);
  }
}

class _PaintedIconAction extends StatefulWidget {
  const _PaintedIconAction({
    required this.label,
    required this.onPressed,
    required this.haptic,
    required this.child,
    required this.size,
    this.transparent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final HapticCue? haptic;
  final Widget child;
  final bool transparent;
  final Size size;

  @override
  State<_PaintedIconAction> createState() => _PaintedIconActionState();
}

class _PaintedIconActionState extends State<_PaintedIconAction> {
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final appearance = GlassAppearance.of(context);
    final fill = widget.transparent
        ? Colors.transparent
        : MediaQuery.highContrastOf(context) || WenkuTheme.isEinkOf(context)
        ? Theme.of(context).colorScheme.surface
        : GlassAppearance.tintOf(
            context,
            opacity: appearance.opacity,
          ).withValues(alpha: appearance.opacity);
    return Semantics(
      label: widget.label,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: const CircleBorder()),
        child: Material(
          type: MaterialType.transparency,
          child: IconButton(
            onPressed: widget.onPressed == null
                ? null
                : () {
                    AppHaptics.play(context, widget.haptic);
                    setState(() => _iconActivation++);
                    widget.onPressed!();
                  },
            icon: widget.child,
            iconSize: 21,
            enableFeedback: false,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tight(widget.size),
            visualDensity: VisualDensity.standard,
            splashColor: Colors.transparent,
            style:
                IconButton.styleFrom(
                  fixedSize: widget.size,
                  shape: const CircleBorder(),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  animationDuration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : WenkuMotion.contact,
                  splashFactory: NoSplash.splashFactory,
                ).copyWith(
                  foregroundBuilder: (context, states, child) =>
                      ArchiveIconContact(
                        pressed: states.contains(WidgetState.pressed),
                        activation: _iconActivation,
                        child: child!,
                      ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.disabled)) {
                      return Colors.transparent;
                    }
                    final alpha =
                        states.contains(WidgetState.pressed) ||
                            states.contains(WidgetState.focused)
                        ? .08
                        : states.contains(WidgetState.hovered)
                        ? .04
                        : 0.0;
                    return Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: alpha);
                  }),
                ),
          ),
        ),
      ),
    );
  }
}

({bool stacked, double height, double extent}) glassActionDockGeometry(
  BuildContext context, {
  required String primary,
  required String secondary,
}) {
  final media = MediaQuery.of(context);
  final width = math.min(
    DockLayout.actionMaxWidth,
    media.size.width -
        media.viewPadding.horizontal -
        DockLayout.actionSideInset * 2,
  );
  final textStyle =
      Theme.of(context).textTheme.bodyMedium ??
      DefaultTextStyle.of(context).style;
  ({double width, double height}) actionSize(String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: appText(context, text),
        style: textStyle.merge(
          const TextStyle(
            fontSize: DockLayout.labelFontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
    )..layout();
    final result = (
      width: painter.width + DockLayout.iconSize + 37,
      height: painter.height + 24,
    );
    painter.dispose();
    return result;
  }

  final first = actionSize(primary);
  final second = actionSize(secondary);
  final rowWidth = math.max(0.0, width - DockLayout.actionGap);
  final stacked =
      second.width > rowWidth * 5 / 12 || first.width > rowWidth * 7 / 12;
  final actionHeight = math.max(
    DockLayout.heightOf(context),
    math.max(first.height, second.height),
  );
  final height = stacked
      ? actionHeight * 2 + DockLayout.actionGap
      : actionHeight;
  return (
    stacked: stacked,
    height: height,
    extent:
        height + DockLayout.bottomPaddingOf(context, viewPadding: true) + 12,
  );
}

({double face, double hit, double scale}) _compactControlGeometry(
  BuildContext context,
) {
  final face = math.max(
    40.0,
    MediaQuery.textScalerOf(context).scale(14) * 1.4 + 12,
  );
  final hit = math.max(48.0, face + 8);
  return (face: face, hit: hit, scale: face / hit);
}

Widget _scaleCompactFace({
  required bool compact,
  required double scaleY,
  double scaleX = 1,
  required Widget child,
}) => compact
    ? _CompactControlFace(scaleX: scaleX, scaleY: scaleY, child: child)
    : child;

class _CompactControlFace extends StatelessWidget {
  const _CompactControlFace({
    required this.scaleX,
    required this.scaleY,
    required this.child,
  });

  final double scaleX;
  final double scaleY;
  final Widget child;

  @override
  Widget build(BuildContext context) => Transform.scale(
    scaleX: scaleX,
    scaleY: scaleY,
    transformHitTests: false,
    child: child,
  );
}

Widget _unscaleCompactContent({
  required bool compact,
  required double scaleY,
  double scaleX = 1,
  required Widget child,
}) => compact
    ? Transform.scale(scaleX: 1 / scaleX, scaleY: 1 / scaleY, child: child)
    : child;

class GlassPillButton extends StatelessWidget {
  const GlassPillButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.height = 54,
    this.iconSize = 18,
    this.fontSize = 14,
    this.compactMainPage = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final double height;
  final double iconSize;
  final double fontSize;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = compactMainPage;
    final geometry = _compactControlGeometry(context);
    final scheme = theme.colorScheme;
    final action = loading ? null : onPressed;
    final color =
        (theme.extension<WenkuTonalColors>()?.action ?? scheme.onSurface)
            .withValues(alpha: action == null ? .45 : 1);
    return Semantics(
      button: true,
      enabled: action != null,
      child: _scaleCompactFace(
        compact: compact,
        scaleY: geometry.scale,
        child: LiquidGlass(
          radius: height / 2,
          thickness: 16,
          elevated: false,
          onTap: action,
          semanticLabel: label,
          child: SizedBox(
            width: 196,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: compact ? geometry.hit : height,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: compact ? 10 : 12,
                ),
                child: _unscaleCompactContent(
                  compact: compact,
                  scaleY: geometry.scale,
                  child: loading
                      ? SizedBox(
                          width: 128,
                          height: 18,
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: color,
                              ),
                            ),
                          ),
                        )
                      : ArchivePart(
                          start: .58,
                          end: 1,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ArchiveIcon(
                                icon,
                                size: compact ? 20 : iconSize,
                                color: color,
                              ),
                              const SizedBox(width: 9),
                              Flexible(
                                child: AppText(
                                  label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: fontSize,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact secondary actions use the same material/press model, not a separate
/// stock button theme.
class GlassTextButton extends StatelessWidget {
  const GlassTextButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.compact = false,
    this.selected,
    this.haptic = HapticCue.action,
    this.pageHeight,
    this.compactMainPage = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final bool compact;
  final bool? selected;
  final HapticCue? haptic;
  final double? pageHeight;
  final bool compactMainPage;

  @override
  Widget build(BuildContext context) {
    final smallFace = compactMainPage;
    final geometry = _compactControlGeometry(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: smallFace ? 0 : 4),
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        selected: selected,
        child: _scaleCompactFace(
          compact: smallFace,
          scaleY: geometry.scale,
          child: LiquidGlass(
            radius: 22,
            elevated: false,
            tintColor: selected == true
                ? Color.lerp(
                    GlassAppearance.tintOf(
                      context,
                      opacity: GlassAppearance.of(context).opacity,
                    ),
                    Theme.of(context).extension<WenkuTonalColors>()?.action ??
                        Theme.of(context).colorScheme.onSurface,
                    .10,
                  )
                : null,
            onTap: onPressed,
            haptic: selected != null && haptic == HapticCue.action
                ? HapticCue.selection
                : haptic,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: compact ? 48 : 64,
                minHeight: smallFace ? geometry.hit : 48,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 14,
                  vertical: 10,
                ),
                child: Align(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: _unscaleCompactContent(
                    compact: smallFace,
                    scaleY: geometry.scale,
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                        color:
                            ((selected == true
                                        ? Theme.of(context)
                                              .extension<WenkuTonalColors>()
                                              ?.action
                                        : null) ??
                                    Theme.of(context).colorScheme.onSurface)
                                .withValues(alpha: onPressed == null ? .45 : 1),
                      ),
                      child: ArchivePart(
                        start: .24,
                        end: .88,
                        travel: const Offset(0, 6),
                        child: child,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget sectionHeader(BuildContext context, String title, String subtitle) =>
    ArchiveSection(
      title: title,
      subtitle: subtitle,
      code: switch (title) {
        '更多书籍' => '02 / ARCHIVE INDEX',
        '简介' => '01 / SYNOPSIS',
        '目录' => '02 / CONTENTS',
        '使用方式' => '00 / READING MODE',
        '阅读偏好' => '01 / READING PROFILE',
        '阅读记录' || '最近阅读' => '02 / READING LOG',
        '离线阅读' => '03 / LOCAL ARCHIVE',
        '玻璃外观' => '04 / OPTICAL SURFACE',
        '本地数据' => '05 / DATA MANAGEMENT',
        '性能诊断' => '06 / DIAGNOSTICS',
        _ => '01 / CATALOG',
      },
    );

class ContentPanel extends StatefulWidget {
  const ContentPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = ArchiveDesign.panelRadius,
    this.backgroundColor,
    this.onTap,
    this.haptic = HapticCue.action,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? backgroundColor;
  final VoidCallback? onTap;
  final HapticCue? haptic;

  @override
  State<ContentPanel> createState() => _ContentPanelState();
}

class _ContentPanelState extends State<ContentPanel> {
  bool _pressed = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: _pressed && !reduceMotion ? .975 : 1,
      duration: reduceMotion
          ? Duration.zero
          : _pressed
          ? WenkuMotion.contact
          : WenkuMotion.enter,
      curve: WenkuMotion.settle,
      child: Material(
        color: widget.backgroundColor ?? Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.radius),
          side: BorderSide(color: Theme.of(context).dividerColor, width: .7),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          enableFeedback: false,
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.play(context, widget.haptic);
                  setState(() => _iconActivation++);
                  widget.onTap!();
                },
          onHighlightChanged: widget.onTap == null
              ? null
              : (pressed) => setState(() => _pressed = pressed),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          child: ArchiveIconContact(
            pressed: _pressed,
            activation: _iconActivation,
            child: ArchiveRegistration(
              child: Padding(padding: widget.padding, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class JellyTapSurface extends StatefulWidget {
  const JellyTapSurface({
    super.key,
    this.tapKey,
    required this.child,
    required this.onTap,
    this.haptic = HapticCue.action,
  });

  final Widget child;
  final Key? tapKey;
  final VoidCallback? onTap;
  final HapticCue? haptic;

  @override
  State<JellyTapSurface> createState() => _JellyTapSurfaceState();
}

class _JellyTapSurfaceState extends State<JellyTapSurface> {
  bool _pressed = false;
  bool _cancelledPress = false;
  int _iconActivation = 0;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: _pressed && !reduceMotion ? .985 : 1,
      duration: reduceMotion || _cancelledPress
          ? Duration.zero
          : _pressed
          ? WenkuMotion.contact
          : WenkuMotion.enter,
      curve: WenkuMotion.settle,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: widget.tapKey,
          enableFeedback: false,
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          onTapCancel: widget.onTap == null
              ? null
              : () => _cancelledPress = true,
          onHighlightChanged: widget.onTap == null
              ? null
              : (pressed) => setState(() {
                  _pressed = pressed;
                  if (pressed) _cancelledPress = false;
                }),
          onTap: widget.onTap == null
              ? null
              : () {
                  AppHaptics.play(context, widget.haptic);
                  setState(() => _iconActivation++);
                  widget.onTap!();
                },
          child: ArchiveIconContact(
            pressed: _pressed,
            activation: _iconActivation,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Consistent recovery/empty states use the same typography, spacing and glass
/// action as the rest of the archive.
class ContentNotice extends StatelessWidget {
  const ContentNotice({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
    this.actionLabel = '重试',
    this.secondaryAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String actionLabel;
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArchiveIcon(
            icon,
            ambient: true,
            size: 34,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          AppText(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            AppText(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            GlassTextButton(onPressed: onRetry, child: AppText(actionLabel)),
          ],
          ?secondaryAction,
        ],
      ),
    ),
  );
}
