// Ported from Wenku8_Flutter (revision ebcd7f1), `lib/app_ui.dart`
// (`showJellySheet`, `GlassMenuAnchor`, `showGlassMenu`,
// `_showGlassOverlay`, `GlassOverlaySurface`, `GlassMenuSource`,
// `GlassMenuSurface`, `GlassMenuItem`, `_GlassOverlayRoute`,
// `_popupSafeRect`, `_GlassMenuPlacement`, `_GlassSheet`) and the
// confirmation pattern from `lib/feature_pages.dart`
// (`confirmNovelAction` -> `confirmArchiveAction`).
//
// Mechanical substitutions:
// - `NativeGlassMorph` -> `WenkuGlassMorph`.
// - `NovelMotion` -> `WenkuMotion`.
// - `_captureGlassSource` resolves its box from the `LiquidGlass` element
//   instead of scanning for the removed `NativeBackdrop`; it folds the
//   compact main-page face scale through `wrapCompactGlassSource`.
// - The material and motion render objects live in
//   `src/glass_overlay_motion.dart`; the sheet/menu composition is unchanged.
//
// fqapp additions (recorded in ADAPTATIONS.md by the integration unit):
// - The route re-scopes the page's derived reduce-motion choice
//   (`MediaQuery.disableAnimations` + `PerformanceScope(explicitReduceMotion)`)
//   into its subtree, because the route is pushed above the page-level
//   `WenkuScope`; upstream relies on an app-level scope instead.
// - `GlassMenuItem` keeps desktop operable: focus ring, Enter/Space activate,
//   Up/Down traverse in `order` sequence, and an `enabled` state.
// - `confirmArchiveAction` carries `destructive`, `confirmKey` and `cancelKey`
//   so callers keep their frozen seams, and names the modal route after its
//   title for assistive technology.
// - `confirmArchiveAction` is the single seam for the history delete/clear
//   confirmation; swapping to `showDialog` only touches this function.
// - Both overlay routes re-read the live `AppUiScope`: the archive style keeps
//   the glass/morph, the classic style renders a Material bottom panel, plain
//   anchored menu and confirmation dialog in the same route, and the caller's
//   content keeps one element (and State) across the switch. Captured reading
//   paper is preserved; only `AppStyleTokens` is refreshed.

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_style_tokens.dart';
import '../app_ui/app_ui_scope.dart';

import 'src/app_text.dart';
import 'src/glass_morph.dart';
import 'src/glass_overlay_motion.dart';
import 'src/performance_preferences.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';
import 'wenku_theme.dart';

Future<T?> showJellySheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool reduceMotion = false,
  bool guardDragDismiss = false,
  ValueListenable<bool>? previewing,
  double? heightFactor,
  double maxWidth = 440,
  double? maxHeight,
  Widget Function(Widget)? surfaceWrapper,
  Rect? anchor,
  BuildContext? sourceContext,
}) => _showGlassOverlay<T>(
  context: context,
  builder: builder,
  reduceMotion: reduceMotion,
  kind: GlassOverlayKind.sheet,
  guardDragDismiss: guardDragDismiss,
  previewing: previewing,
  heightFactor: heightFactor,
  maxWidth: maxWidth,
  maxHeight: maxHeight,
  surfaceWrapper: surfaceWrapper,
  anchor: anchor,
  sourceContext: sourceContext,
);

/// The trigger holds its layout slot while its material stretches into the
/// route. Restore it after the reverse transition, never behind a second lens.
class GlassMenuAnchor extends StatefulWidget {
  const GlassMenuAnchor({super.key, required this.child});
  final Widget child;

  @override
  State<GlassMenuAnchor> createState() => _GlassMenuAnchorState();
}

class _GlassMenuAnchorState extends State<GlassMenuAnchor> {
  bool open = false;

  void setOpen(bool value) {
    if (mounted && open != value) setState(() => open = value);
  }

  @override
  Widget build(BuildContext context) {
    // The classic menu is an ordinary Material popup: nothing stretches out of
    // the trigger, so the trigger must stay visible and operable. Reading the
    // live scope (not the style the menu opened with) also restores a trigger
    // that was hidden by an archive menu when the user switches style while it
    // is still open.
    final hidden = open && !AppUiScope.isClassic(context);
    return IgnorePointer(
      ignoring: hidden,
      child: ExcludeSemantics(
        excluding: hidden,
        child: Opacity(opacity: hidden ? 0 : 1, child: widget.child),
      ),
    );
  }
}

final _activeGlassOverlays = Expando<bool>('active-glass-overlay');

GlassMenuSource? _captureGlassSource(
  BuildContext context,
  NavigatorState navigator,
) {
  GlassMenuSource? source;
  void capture(Element element) {
    if (source != null) return;
    final widget = element.widget;
    if (widget is LiquidGlass) {
      final render = element.findRenderObject();
      final foreground = Padding(padding: widget.padding, child: widget.child);
      source = GlassMenuSource(
        box: render is RenderBox && render.attached && render.hasSize
            ? render
            : null,
        radius: widget.radius,
        thickness: widget.thickness,
        blur: widget.blur ?? 0,
        foreground: InheritedTheme.capture(
          from: element,
          to: navigator.context,
        ).wrap(wrapCompactGlassSource(element, foreground)),
      );
      return;
    }
    element.visitChildElements(capture);
  }

  capture(context as Element);
  return source;
}

Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool reduceMotion = false,
  bool preferBelow = false,
  // The settings row adapter keeps its previous behaviour: the trigger stays
  // in the tree (hidden by `GlassMenuAnchor`) and the route does not paint a
  // second copy of its foreground. Archive menus keep the upstream morph.
  bool captureSource = true,
}) async {
  if (!context.mounted) return null;
  if (_activeGlassOverlays[context] == true) return null;
  final owner = context.findAncestorStateOfType<_GlassMenuAnchorState>();
  if (owner?.open ?? false) return null;
  final navigator = Navigator.of(context);
  final box = context.findRenderObject();
  final overlay = navigator.overlay?.context.findRenderObject();
  if (box is! RenderBox ||
      overlay is! RenderBox ||
      !box.attached ||
      !box.hasSize ||
      box.size.isEmpty) {
    return null;
  }
  final appearance = GlassAppearance.of(context);
  // Classic menus keep the plain trigger and have no morph, so capturing the
  // liquid-glass material/foreground would only clone a face nobody paints.
  final classic = AppUiScope.isClassic(context);
  final source = captureSource && !classic
      ? _captureGlassSource(context, navigator)
      : null;
  final sourceBox = source?.box ?? box;
  // The page's performance/e-ink/reduce-motion choice lives below the root
  // Navigator (`WenkuScope` is inside the page), so the route must carry it
  // for its contents to read the same choice.
  final reduce =
      reduceMotion ||
      PerformanceScope.reduceMotionOf(context) ||
      MediaQuery.disableAnimationsOf(context);
  final route = _GlassOverlayRoute<T>(
    builder: builder,
    reduceMotion: reduce,
    classicAtOpen: classic,
    performance: PerformanceScope.of(context),
    appearance: appearance,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    kind: GlassOverlayKind.menu,
    preferBelow: preferBelow,
    // Layout, stretching and hit testing all use the owning Overlay's space.
    // A global offset is wrong for an inset/scaled/nested Navigator.
    anchor: MatrixUtils.transformRect(
      sourceBox.getTransformTo(overlay),
      Offset.zero & sourceBox.size,
    ),
    source: source,
  );
  owner?.setOpen(true);
  _activeGlassOverlays[context] = true;
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await navigator.push<T>(route);
    await route.completed;
    return result;
  } finally {
    _activeGlassOverlays[context] = false;
    owner?.setOpen(false);
  }
}

Future<T?> _showGlassOverlay<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool reduceMotion,
  required GlassOverlayKind kind,
  bool guardDragDismiss = false,
  bool classicDialog = false,
  Rect? anchor,
  BuildContext? sourceContext,
  ValueListenable<bool>? previewing,
  double? heightFactor,
  double maxWidth = 440,
  double? maxHeight,
  Widget Function(Widget)? surfaceWrapper,
}) async {
  if (!context.mounted) return null;
  if (_activeGlassOverlays[context] == true) return null;
  final navigator = Navigator.of(context);
  final classic = AppUiScope.isClassic(context);
  final sourceBox = sourceContext?.findRenderObject();
  final source = sourceContext == null || classic
      ? null
      : _captureGlassSource(sourceContext, navigator);
  final owner = sourceContext?.findAncestorStateOfType<_GlassMenuAnchorState>();
  final reduce =
      reduceMotion ||
      PerformanceScope.reduceMotionOf(context) ||
      MediaQuery.disableAnimationsOf(context);
  final route = _GlassOverlayRoute<T>(
    builder: builder,
    kind: kind,
    classicAtOpen: classic,
    classicDialog: classicDialog,
    anchor: anchor,
    anchorBox: sourceBox is RenderBox && sourceBox.attached && sourceBox.hasSize
        ? sourceBox
        : null,
    source: source,
    reduceMotion: reduce,
    performance: PerformanceScope.of(context),
    appearance: GlassAppearance.of(context),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    previewing: previewing,
    heightFactor: heightFactor,
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    surfaceWrapper: surfaceWrapper,
    guardDragDismiss: guardDragDismiss,
  );
  _activeGlassOverlays[context] = true;
  owner?.setOpen(true);
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await navigator.push<T>(route);
    // Do not reflow/load the obscured page during the reverse animation.
    await route.completed;
    return result;
  } finally {
    _activeGlassOverlays[context] = false;
    owner?.setOpen(false);
  }
}

class GlassOverlaySurface extends StatefulWidget {
  const GlassOverlaySurface({
    super.key,
    required this.child,
    this.preserveOptics = false,
    this.morph,
    this.transparent = false,
  });
  final Widget child;
  final bool preserveOptics;
  final WenkuGlassMorph? morph;
  final bool transparent;

  @override
  State<GlassOverlaySurface> createState() => _GlassOverlaySurfaceState();
}

/// The corner radii of a glass overlay and the rows inside it.
///
/// The menu's frame and its rows are one object: a selected row that fills a
/// corner needs the frame's radius less the inset the menu pads its content
/// by, so the two stay concentric instead of reading as two shapes.
class GlassOverlayRadii {
  const GlassOverlayRadii._();

  /// The menu's frame.
  static const double menu = 28;

  /// A row inside the menu: the frame's radius less the 8dp the menu insets
  /// its content by, so a selected row that fills a corner stays concentric
  /// with the frame instead of reading as a square block.
  static const double menuItem = 20;
}

class _GlassOverlaySurfaceState extends State<GlassOverlaySurface> {
  // Keep the active slider/gesture state when switching between the filtered
  // surface and its transparent preview, including lightweight renderers.
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    return LiquidGlass(
      transparent: widget.transparent,
      radius: GlassOverlayRadii.menu,
      thickness: 20,
      elevated: false,
      preserveOptics: widget.preserveOptics,
      morph: widget.morph,
      // Panels contain several labels: soften the underlying text/controls so
      // they do not read as a second, stationary set of foreground glyphs.
      // The shared tint/opacity stays untouched; navigation keeps its clear
      // core.
      blur: math.min(12, GlassAppearance.of(context).blur),
      child: content,
    );
  }
}

class GlassMenuSource {
  const GlassMenuSource({
    required this.foreground,
    this.radius = 24,
    this.thickness = 20,
    this.blur = 0,
    this.box,
  });
  final Widget foreground;
  final double radius;
  final double thickness;
  final double blur;
  final RenderBox? box;
}

/// Both the route and rendering fixtures use this same material/content split.
class GlassMenuSurface extends StatelessWidget {
  const GlassMenuSurface({
    super.key,
    required this.animation,
    required this.anchor,
    required this.child,
    this.source,
    this.reduceMotion = false,
  });
  final Animation<double> animation;
  final Rect anchor;
  final Widget child;
  final GlassMenuSource? source;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final reduced = reduceMotion || MediaQuery.disableAnimationsOf(context);
    return GlassOverlaySurface(
      preserveOptics: true,
      morph: reduced
          ? null
          : WenkuGlassMorph(
              animation: animation,
              radius: source?.radius ?? 24,
              thickness: source?.thickness ?? 20,
              blur: source?.blur ?? 0,
            ),
      child: reduced
          ? child
          : GlassMenuContents(
              animation: animation,
              sourceSize: anchor.size,
              sourceRadius: source?.radius ?? 24,
              source: source?.foreground ?? const SizedBox.shrink(),
              child: ArchiveMotionScope(animation: animation, child: child),
            ),
    );
  }
}

/// One menu row. Upstream semantics and paint are kept; fqapp adds a visible
/// focus ring, keyboard activation and traversal so the desktop build is
/// operable without a pointer.
class GlassMenuItem extends StatefulWidget {
  const GlassMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.enabled = true,
    this.order = 0,
    this.icon,
    this.autofocus = false,
  });
  final String label;
  final VoidCallback onPressed;
  final bool selected, enabled;
  final int order;
  final IconData? icon;
  final bool autofocus;

  @override
  State<GlassMenuItem> createState() => _GlassMenuItemState();
}

class _GlassMenuItemState extends State<GlassMenuItem> {
  bool _focused = false;

  void _activate() {
    if (!widget.enabled) return;
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final body = AppUiScope.isClassic(context)
        ? _classicRow(context)
        : _archiveRow(context);
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.order.toDouble()),
      child: FocusableActionDetector(
        enabled: widget.enabled,
        autofocus: widget.autofocus,
        onShowFocusHighlight: (value) {
          if (mounted && _focused != value) setState(() => _focused = value);
        },
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
          NextFocusIntent: CallbackAction<NextFocusIntent>(
            onInvoke: (_) {
              FocusScope.of(context).nextFocus();
              return null;
            },
          ),
          PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
            onInvoke: (_) {
              FocusScope.of(context).previousFocus();
              return null;
            },
          ),
        },
        // Keep the row a single focus target: the jelly tap surface's InkWell
        // would otherwise add a second, inner node and swallow traversal.
        child: ExcludeFocus(
          child: Opacity(opacity: widget.enabled ? 1 : .42, child: body),
        ),
      ),
    );
  }

  /// Classic menus are ordinary Material popups: a flat row with an ink
  /// response, not an archive material clone. Selection and focus stay visible
  /// without the archive marks.
  Widget _classicRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected && widget.enabled;
    return Semantics(
      selected: selected,
      enabled: widget.enabled,
      child: InkWell(
        onTap: widget.enabled ? _activate : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? scheme.primary.withValues(alpha: .10) : null,
            borderRadius: BorderRadius.circular(8),
            border: _focused && widget.enabled
                ? Border.all(color: scheme.primary, width: 1.6)
                : null,
          ),
          child: Row(
            children: [
              if (widget.icon != null)
                Icon(widget.icon, size: 20, color: scheme.onSurfaceVariant)
              else
                ExcludeSemantics(
                  child: SizedBox(
                    width: 3,
                    height: 3,
                    child: ColoredBox(
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              SizedBox(width: widget.icon == null ? 10 : 12),
              Expanded(
                child: AppText(
                  widget.label,
                  style: TextStyle(
                    color: selected ? scheme.primary : null,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected)
                Icon(
                  CupertinoIcons.check_mark,
                  size: 17,
                  color: scheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _archiveRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected && widget.enabled;
    return Semantics(
      selected: selected,
      enabled: widget.enabled,
      child: JellyTapSurface(
        onTap: widget.enabled ? _activate : null,
        haptic: HapticCue.selection,
        child: GlassForeground(
          child: ArchivePart(
            start: .06 + widget.order.clamp(0, 8) * .025,
            end: .62 + widget.order.clamp(0, 8) * .025,
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.onSurface.withValues(alpha: .9)
                    : Colors.transparent,
                // The selected row is a block *inside* the menu, so it takes
                // the menu's own corner radius less the 8dp the menu pads its
                // content by. It used to use `panelRadius` (4dp) against a
                // 28dp frame, which put a small square block in a large round
                // sheet - the one control that carried two shapes.
                borderRadius: BorderRadius.circular(GlassOverlayRadii.menuItem),
                border: _focused && widget.enabled
                    // Invert against the fill so the ring stays visible on the
                    // selected row, whose fill is `onSurface`.
                    ? Border.all(
                        color: selected ? scheme.surface : scheme.onSurface,
                        width: 1.6,
                      )
                    : null,
              ),
              child: Row(
                children: [
                  if (widget.icon != null)
                    ArchiveIcon(widget.icon, size: 20)
                  else
                    ExcludeSemantics(
                      child: SizedBox(
                        width: 3,
                        height: 3,
                        child: ColoredBox(
                          color: selected
                              ? scheme.surface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  SizedBox(width: widget.icon == null ? 10 : 14),
                  Expanded(
                    child: AppText(
                      widget.label,
                      style: TextStyle(
                        color: selected ? scheme.surface : null,
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (selected)
                    ArchiveIcon(
                      CupertinoIcons.check_mark,
                      size: 17,
                      color: scheme.surface,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassOverlayRoute<T> extends PopupRoute<T>
    with AppHapticModalBarrier<T> {
  _GlassOverlayRoute({
    required this.builder,
    required this.kind,
    required this.reduceMotion,
    required this.performance,
    required this.appearance,
    required this.themes,
    this.classicAtOpen = false,
    this.classicDialog = false,
    this.anchor,
    this.anchorBox,
    this.source,
    this.previewing,
    this.heightFactor,
    this.maxWidth = 440,
    this.maxHeight,
    this.surfaceWrapper,
    this.preferBelow = false,
    this.guardDragDismiss = false,
  }) : _classicForBarrier = classicAtOpen;
  final WidgetBuilder builder;
  final GlassOverlayKind kind;
  final bool reduceMotion;

  /// Style at push time. Entry/exit policy is fixed for one flight; the body
  /// keeps reading the live scope so a switch while open only swaps chrome.
  final bool classicAtOpen;

  /// Last live style seen by the barrier/page build. The actual barrier is
  /// built through [barrierColorOf] (which reads the scope directly); this
  /// keeps the metadata getter (`ModalRoute.barrierColor`) in sync for callers
  /// and tests that read it after a switch.
  bool _classicForBarrier;

  /// Renders the classic confirm as a centred dialog instead of a sheet. The
  /// archive style keeps its bottom sheet for the same route.
  final bool classicDialog;
  final PerformancePreferences performance;
  final GlassAppearance appearance;
  final CapturedThemes themes;

  /// Stable owner for the caller's content. Classic and archive use different
  /// shell widget types, so this key is what carries an open editor, input or
  /// scroll position across a style switch in either direction.
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'overlay-content');

  /// Owns the menu scroll container above the shell branch. The scrollable
  /// Element (and therefore its offset) moves between the archive and classic
  /// surfaces instead of being recreated at offset 0.
  final GlobalKey _menuScrollKey = GlobalKey(debugLabel: 'overlay-menu-scroll');

  final Rect? anchor;
  final RenderBox? anchorBox;
  final GlassMenuSource? source;
  final ValueListenable<bool>? previewing;
  final double? heightFactor;
  final double maxWidth;
  final double? maxHeight;
  final Widget Function(Widget)? surfaceWrapper;
  final bool preferBelow;
  final bool guardDragDismiss;

  @override
  void install() {
    super.install();
    previewing?.addListener(changedInternalState);
  }

  @override
  void dispose() {
    previewing?.removeListener(changedInternalState);
    super.dispose();
  }

  static const _classicEnter = Duration(milliseconds: 250);
  static const _classicExit = Duration(milliseconds: 200);

  @override
  Duration get transitionDuration => reduceMotion
      ? Duration.zero
      : classicAtOpen
      ? _classicEnter
      : WenkuMotion.enter;
  @override
  Duration get reverseTransitionDuration => reduceMotion
      ? Duration.zero
      : classicAtOpen
      ? _classicExit
      : WenkuMotion.exit;
  @override
  bool get barrierDismissible => true;

  /// The scrim is presentation, not entry/exit motion: it follows the live
  /// style for the whole life of an open route. Only [classicAtOpen] stays
  /// frozen (transition duration).
  @override
  Color? barrierColorOf(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    _classicForBarrier = classic;
    return _barrierColor(
      classic: classic,
      menu: kind == GlassOverlayKind.menu,
      previewing: previewing?.value ?? false,
    );
  }

  @override
  Color get barrierColor => _barrierColor(
    classic: _classicForBarrier,
    menu: kind == GlassOverlayKind.menu,
    previewing: previewing?.value ?? false,
  );

  static Color _barrierColor({
    required bool classic,
    required bool menu,
    required bool previewing,
  }) {
    if (menu || previewing) return Colors.transparent;
    // A plain Material sheet/dialog dims the page; the archive plate keeps its
    // light scrim so the milk paper stays visible behind it.
    return classic
        ? Colors.black.withValues(alpha: .5)
        : Colors.black.withValues(alpha: .16);
  }

  @override
  String get barrierLabel => '关闭弹层';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // The route outlives a style switch: read the live scope here (and again in
    // the shell widgets) so an already-open sheet/menu swaps chrome instead of
    // keeping the style captured with `themes`.
    final classic = AppUiScope.isClassic(context);
    _classicForBarrier = classic;
    final overlay =
        navigator!.overlay!.context.findRenderObject()! as RenderBox;
    final trigger = anchorBox;
    final origin = trigger != null && trigger.attached && trigger.hasSize
        ? MatrixUtils.transformRect(
            trigger.getTransformTo(overlay),
            Offset.zero & trigger.size,
          )
        : anchor;
    final dockSheet =
        kind == GlassOverlayKind.sheet && origin != null && source != null;
    // One stable element for the caller's content: the classic and archive
    // shells are different widget types, and only this key lets the content's
    // State (query controller, draft, scroll offset, focus) move between them.
    final content = KeyedSubtree(
      key: _contentKey,
      child: Builder(builder: builder),
    );
    final Widget material;
    if (kind == GlassOverlayKind.menu) {
      // The scroll container is route-owned (above the shell branch) so the
      // Scrollable Element keeps its offset when the menu swaps surfaces.
      final menuScroll = KeyedSubtree(
        key: _menuScrollKey,
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.all(8),
          child: ArchiveMotionScope(
            animation: animation,
            enabled: !reduceMotion && !classic,
            child: content,
          ),
        ),
      );
      material = classic
          ? _ClassicMenuSurface(
              animation: animation,
              reduceMotion: reduceMotion,
              child: menuScroll,
            )
          : GlassOverlayTransition(
              animation: animation,
              kind: GlassOverlayKind.menu,
              reduceMotion: reduceMotion,
              anchor: origin,
              coordinateSpace: overlay,
              child: GlassMenuSurface(
                animation: animation,
                anchor: origin!,
                source: source,
                reduceMotion: reduceMotion,
                child: menuScroll,
              ),
            );
    } else if (classic && classicDialog) {
      material = _ClassicDialogSurface(
        animation: animation,
        reduceMotion: reduceMotion,
        child: content,
      );
    } else if (classic) {
      material = _ClassicSheetTransition(
        animation: animation,
        reduceMotion: reduceMotion,
        child: _GlassSheet(
          classic: true,
          reduceMotion: reduceMotion,
          guardDragDismiss: guardDragDismiss,
          previewing: previewing,
          child: content,
        ),
      );
    } else {
      material = GlassOverlayTransition(
        animation: animation,
        kind: dockSheet ? GlassOverlayKind.menu : kind,
        reduceMotion: reduceMotion,
        anchor: origin,
        coordinateSpace: overlay,
        child: _GlassSheet(
          reduceMotion: reduceMotion,
          guardDragDismiss: guardDragDismiss,
          previewing: previewing,
          animation: animation,
          anchor: dockSheet ? origin : null,
          source: dockSheet ? source : null,
          child: ArchiveMotionScope(
            animation: animation,
            enabled: !reduceMotion,
            child: content,
          ),
        ),
      );
    }
    // A captured reader Theme, like surfaceWrapper's own paper Theme, still
    // carries the style tokens it opened with. Apply the live discrete
    // constants inside that Theme instead of freezing the old style.
    final styled = _LiveAppStyleTokens(child: material);
    final surface = surfaceWrapper?.call(styled) ?? styled;
    // Scope the page's reduce-motion choice into the route subtree. The route
    // is pushed on the root Navigator, so it does not inherit the page-level
    // `WenkuScope` MediaQuery/PerformanceScope; without this, controls inside
    // the sheet (jelly press, animated segments) keep animating.
    return themes.wrap(
      MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations:
              MediaQuery.disableAnimationsOf(context) || reduceMotion,
        ),
        child: PerformanceScope(
          preferences: performance,
          explicitReduceMotion: reduceMotion,
          child: GlassAppearance(
            blur: appearance.blur,
            opacity: appearance.opacity,
            child: Material(
              type: MaterialType.transparency,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final safe = _popupSafeRect(
                    overlay,
                    constraints.biggest,
                    MediaQuery.of(context),
                  );
                  if (kind == GlassOverlayKind.menu) {
                    return CustomSingleChildLayout(
                      delegate: _GlassMenuPlacement(origin!, safe, preferBelow),
                      child: surface,
                    );
                  }
                  if (classic && classicDialog) {
                    // Center inside the keyboard/safe rect, not the whole
                    // overlay: `safe` is already in this Overlay's coordinate
                    // space (nested Navigators included). Keep a scroll view
                    // for landscape/split heights.
                    if (safe.isEmpty) return const SizedBox.shrink();
                    final margin = math.min(
                      24.0,
                      math.min(safe.width, safe.height) / 4,
                    );
                    final availableWidth = math.max(
                      0.0,
                      safe.width - margin * 2,
                    );
                    final availableHeight = math.max(
                      0.0,
                      safe.height - margin * 2,
                    );
                    final dialogWidth = math.min(
                      math.min(maxWidth, 420.0),
                      availableWidth,
                    );
                    final dialogHeight = math.min(
                      maxHeight ?? double.infinity,
                      availableHeight,
                    );
                    return Stack(
                      children: [
                        Positioned.fromRect(
                          rect: safe,
                          child: Padding(
                            padding: EdgeInsets.all(margin),
                            child: Center(
                              // The height cap belongs outside the scroll
                              // view: inside, it would bound the Column too
                              // and leave nothing to scroll.
                              child: SizedBox(
                                width: dialogWidth,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: dialogHeight,
                                  ),
                                  child: SingleChildScrollView(
                                    primary: false,
                                    child: surface,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  final width = math.min(
                    maxWidth,
                    math.max(0.0, safe.width - 24),
                  );
                  final sheetBottom = math.min(
                    dockSheet ? origin.bottom : origin?.top ?? safe.bottom,
                    safe.bottom,
                  );
                  final height = math.min(
                    maxHeight ?? double.infinity,
                    math.max(0.0, sheetBottom - safe.top - 22),
                  );
                  return Stack(
                    children: [
                      Positioned(
                        left: safe.center.dx - width / 2,
                        bottom:
                            math.max(0, constraints.maxHeight - sheetBottom) +
                            (dockSheet
                                ? 0
                                : origin == null
                                ? 10
                                : 8),
                        width: width,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: height),
                          child: heightFactor == null
                              ? surface
                              : SizedBox(
                                  height: math.min(760, height * heightFactor!),
                                  child: surface,
                                ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Window insets are expressed in view coordinates, not an inset Navigator's
// local coordinates. Intersect once; do not add keyboard + bottom safe area.
Rect _popupSafeRect(RenderBox overlay, Size size, MediaQueryData media) {
  final padding = media.padding;
  final keyboard = media.viewInsets;
  final left = math.max(padding.left, keyboard.left);
  final top = math.max(padding.top, keyboard.top);
  final global = Rect.fromLTRB(
    left,
    top,
    math.max(left, media.size.width - math.max(padding.right, keyboard.right)),
    math.max(
      top,
      media.size.height - math.max(padding.bottom, keyboard.bottom),
    ),
  );
  final inverse = Matrix4.tryInvert(overlay.getTransformTo(null));
  final local = inverse == null
      ? Rect.zero
      : MatrixUtils.transformRect(inverse, global);
  final clipped = local.intersect(Offset.zero & size);
  if (clipped.width >= 0 && clipped.height >= 0) return clipped;
  return Rect.fromLTWH(
    local.left.clamp(0, size.width),
    local.top.clamp(0, size.height),
    0,
    0,
  );
}

class _GlassMenuPlacement extends SingleChildLayoutDelegate {
  _GlassMenuPlacement(this.anchor, this.safe, this.preferBelow);
  final Rect anchor;
  final Rect safe;
  final bool preferBelow;
  Rect get available => Rect.fromLTWH(
    safe.left + math.min(12, safe.width / 2),
    math.min(safe.top + math.min(12, safe.height / 2), math.max(0, anchor.top)),
    math.max(0, safe.width - 24),
    math.max(0, safe.height - 24),
  );
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(248, available.width),
        maxWidth: math.min(248, available.width),
        maxHeight: available.height,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final area = available;
    final x = (anchor.right - childSize.width).clamp(
      area.left,
      math.max(area.left, area.right - childSize.width),
    );
    final below = preferBelow ? anchor.bottom + 8 : anchor.top;
    final y = below + childSize.height <= area.bottom
        ? below
        : (preferBelow ? anchor.top - 8 : anchor.bottom) - childSize.height;
    return Offset(
      x.toDouble(),
      y.clamp(area.top, math.max(area.top, area.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_GlassMenuPlacement oldDelegate) =>
      anchor != oldDelegate.anchor ||
      safe != oldDelegate.safe ||
      preferBelow != oldDelegate.preferBelow;
}

class _GlassSheet extends StatefulWidget {
  const _GlassSheet({
    required this.child,
    required this.reduceMotion,
    this.classic = false,
    this.guardDragDismiss = false,
    this.previewing,
    this.animation,
    this.anchor,
    this.source,
  });
  final Widget child;
  final bool reduceMotion;

  /// Plain Material panel instead of the archive glass plate. Drag-to-dismiss,
  /// preview transparency and guardDragDismiss stay identical.
  final bool classic;
  final bool guardDragDismiss;
  final ValueListenable<bool>? previewing;
  final Animation<double>? animation;
  final Rect? anchor;
  final GlassMenuSource? source;
  @override
  State<_GlassSheet> createState() => _GlassSheetState();
}

class _GlassSheetState extends State<_GlassSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );
  final _surfaceKey = GlobalKey();
  bool _cancelled = false;
  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _restore() {
    if (widget.reduceMotion || MediaQuery.disableAnimationsOf(context)) {
      _drag.value = 0;
    } else {
      _drag.animateTo(0, duration: WenkuMotion.enter, curve: WenkuMotion.ease);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _cancelled = false,
    onPointerCancel: (_) => _cancelled = true,
    child: GestureDetector(
      onVerticalDragStart: (_) => _drag.stop(),
      onVerticalDragUpdate: (details) =>
          _drag.value = math.max(0, _drag.value + details.delta.dy),
      onVerticalDragEnd: (details) {
        if (_cancelled) {
          _restore();
          return;
        }
        final box =
            _surfaceKey.currentContext!.findRenderObject()! as RenderBox;
        if ((details.primaryVelocity ?? 0) > 550 ||
            _drag.value > box.size.height * .24) {
          AppHaptics.play(context, HapticCue.action);
          if (widget.guardDragDismiss) {
            // Editors opt in without changing existing sheets' drag contract.
            if (ModalRoute.of(context)?.popDisposition ==
                RoutePopDisposition.doNotPop) {
              _restore();
            }
            Navigator.of(context).maybePop();
          } else {
            Navigator.of(context).pop();
          }
        } else {
          _restore();
        }
      },
      onVerticalDragCancel: _restore,
      child: AnimatedBuilder(
        animation: _drag,
        child: RepaintBoundary(
          child: widget.classic
              ? ValueListenableBuilder<bool>(
                  valueListenable:
                      widget.previewing ?? const AlwaysStoppedAnimation(false),
                  builder: (context, previewing, child) => Material(
                    key: _surfaceKey,
                    // Preview removes only the panel material, like the
                    // archive plate; the foreground stays visible and keeps
                    // owning its gestures.
                    color: previewing
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.surface,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                    ),
                    child: child,
                  ),
                  child: _contents(context),
                )
              : ValueListenableBuilder<bool>(
                  valueListenable:
                      widget.previewing ?? const AlwaysStoppedAnimation(false),
                  builder: (context, previewing, child) {
                    return GlassOverlaySurface(
                      key: _surfaceKey,
                      transparent: previewing,
                      preserveOptics: widget.source != null,
                      morph:
                          widget.source == null ||
                              widget.reduceMotion ||
                              MediaQuery.disableAnimationsOf(context)
                          ? null
                          : WenkuGlassMorph(
                              animation: widget.animation!,
                              radius: widget.source!.radius,
                              thickness: widget.source!.thickness,
                              blur: widget.source!.blur,
                            ),
                      child: child!,
                    );
                  },
                  child: _contents(context),
                ),
        ),
        builder: (context, child) => Transform.translate(
          key: const ValueKey('glass-sheet-drag'),
          offset: Offset(0, _drag.value),
          child: child,
        ),
      ),
    ),
  );

  Widget _contents(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The grabber belongs to the glass plate; a classic Material sheet
        // starts with the caller's content.
        if (!widget.classic) ...[
          const SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable:
                widget.previewing ?? const AlwaysStoppedAnimation(false),
            builder: (context, previewing, child) =>
                Opacity(opacity: previewing ? 0 : 1, child: child),
            child: Container(
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
        Flexible(child: widget.child),
      ],
    );
    if (widget.classic ||
        widget.source == null ||
        widget.reduceMotion ||
        MediaQuery.disableAnimationsOf(context)) {
      return content;
    }
    return GlassMenuContents(
      animation: widget.animation!,
      sourceSize: widget.anchor!.size,
      sourceRadius: widget.source!.radius,
      source: widget.source!.foreground,
      child: content,
    );
  }
}

/// Only an explicit confirmation returns true; the barrier, the system back
/// gesture and the cancel row all return false.
///
/// This is the single seam for the history delete/clear confirmation. Keeping
/// the `showJellySheet` call here means a host that must fall back to
/// `showDialog` changes one function, not its call sites.
///
/// The route is shared by both styles: archive keeps its glass bottom sheet,
/// classic renders a Material confirmation dialog in the same route, so a style
/// switch while the confirmation is open never replaces the route. Only an
/// explicit confirm returns true; the barrier, system back and cancel row
/// return false in both styles.
Future<bool> confirmArchiveAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool reduceMotion = false,
  bool destructive = true,
  Key? confirmKey,
  Key? cancelKey,
}) async =>
    await _showGlassOverlay<bool>(
      context: context,
      reduceMotion: reduceMotion,
      kind: GlassOverlayKind.sheet,
      classicDialog: true,
      builder: (sheet) => Semantics(
        key: const ValueKey('archive-confirm'),
        namesRoute: true,
        label: title,
        child: AppUiScope.isClassic(sheet)
            ? _ClassicConfirmBody(
                title: title,
                message: message,
                confirmLabel: confirmLabel,
                destructive: destructive,
                confirmKey: confirmKey,
                cancelKey: cancelKey,
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      title,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    AppText(message),
                    const SizedBox(height: 24),
                    GlassTextButton(
                      key: confirmKey,
                      onPressed: () => Navigator.pop(sheet, true),
                      haptic: destructive
                          ? HapticCue.warning
                          : HapticCue.action,
                      child: AppText(confirmLabel),
                    ),
                    const SizedBox(height: 8),
                    GlassTextButton(
                      key: cancelKey,
                      onPressed: () => Navigator.pop(sheet, false),
                      child: const AppText('取消'),
                    ),
                  ],
                ),
              ),
      ),
    ) ==
    true;

/// Material confirmation body for the classic style: same strings, same
/// explicit-result contract as the archive sheet.
class _ClassicConfirmBody extends StatelessWidget {
  const _ClassicConfirmBody({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.destructive,
    this.confirmKey,
    this.cancelKey,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;
  final Key? confirmKey;
  final Key? cancelKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          AppText(message),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: cancelKey,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: confirmKey,
                onPressed: () => Navigator.pop(context, true),
                style: destructive
                    ? TextButton.styleFrom(foregroundColor: scheme.error)
                    : null,
                child: Text(confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Applies the live discrete [AppStyleTokens] on top of whatever Theme is
/// already in scope.
///
/// The overlay route re-provides the page Theme captured at push time, and
/// `surfaceWrapper` (reader paper) can add another one. Neither updates when the
/// user switches classic/archive, so archive widgets below would keep the old
/// tokens. This replaces only the style extension (paper, brightness and
/// motion stay as captured) and re-reads the live scope on every change.
class _LiveAppStyleTokens extends StatelessWidget {
  const _LiveAppStyleTokens({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final tokens = AppUiScope.presentationOf(context).tokens;
    return Theme(
      data: base.copyWith(extensions: _withLiveTokens(base, tokens)),
      child: child,
    );
  }

  static Iterable<ThemeExtension<dynamic>> _withLiveTokens(
    ThemeData base,
    AppStyleTokens tokens,
  ) sync* {
    for (final extension in base.extensions.values) {
      if (extension is! AppStyleTokens) yield extension;
    }
    yield tokens;
  }
}

/// Classic bottom-sheet entry: the old Material panel slides in from the bottom
/// instead of the archive plane/liquid-glass morph.
class _ClassicSheetTransition extends StatelessWidget {
  const _ClassicSheetTransition({
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion || MediaQuery.disableAnimationsOf(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}

/// Classic anchored menu: an ordinary Material popup panel with a plain fade.
class _ClassicMenuSurface extends StatelessWidget {
  const _ClassicMenuSurface({
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final panel = Material(
      color: theme.colorScheme.surface,
      elevation: 8,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant, width: .6),
      ),
      child: child,
    );
    if (reduceMotion || MediaQuery.disableAnimationsOf(context)) return panel;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: panel,
    );
  }
}

/// Classic confirmation: a centred Material dialog card in the same popup
/// route as the archive sheet.
class _ClassicDialogSurface extends StatelessWidget {
  const _ClassicDialogSurface({
    required this.animation,
    required this.reduceMotion,
    required this.child,
  });

  final Animation<double> animation;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Material(
      color: theme.colorScheme.surface,
      elevation: 24,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: child,
    );
    if (reduceMotion || MediaQuery.disableAnimationsOf(context)) return card;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: .94, end: 1).animate(curved),
        child: card,
      ),
    );
  }
}
