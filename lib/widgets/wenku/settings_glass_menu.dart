// Ported from Wenku8_Flutter (revision ebcd7f1):
//   lib/setting_menu.dart -> GlassSettingMenu
//   lib/app_ui.dart       -> GlassMenuAnchor, showGlassMenu, GlassMenuItem,
//                            _GlassMenuPlacement, _popupSafeRect
//
// Mechanical substitutions for dependencies fqapp does not carry:
// - The upstream `_GlassOverlayRoute` material morph (`NativeBackdrop`,
//   `NativeGlassMorph`, `GlassOverlayTransition`, `_captureGlassSource`) is not
//   carried. The menu is a [PopupRoute] with a transparent barrier and a
//   [LiquidGlass] panel; the morph is replaced by a 120ms fade/scale and the
//   upstream `_GlassMenuPlacement` math still anchors the panel to the source
//   control's rect.
// - `NovelMotion` -> `WenkuMotion` (same contact/enter/exit durations).
// - `app_ui.dart` AppText/ArchivePart/ArchiveIcon/GlassForeground ->
//   the shared `wenku_ui.dart` exports.
// - `ArchiveDesign.panelRadius` -> `wenku_archive.dart` (unchanged value).
// - The upstream persisted haptics service is absent; menu taps keep
//   HapticCue.selection through JellyTapSurface.
// - `MediaQuery.disableAnimationsOf(context)` supplies the reduce-motion flag,
//   exactly as the upstream call sites do.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';
import 'wenku_theme.dart';

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
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: open,
    child: ExcludeSemantics(
      excluding: open,
      child: Opacity(opacity: open ? 0 : 1, child: widget.child),
    ),
  );
}

/// Upstream `showGlassMenu`: anchor an archive menu to the control that opened
/// it. The menu owns a transparent barrier, so tapping anywhere else closes it.
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool reduceMotion = false,
  bool preferBelow = false,
}) async {
  if (!context.mounted) return null;
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
  final origin = MatrixUtils.transformRect(
    box.getTransformTo(overlay),
    Offset.zero & box.size,
  );
  final appearance = GlassAppearance.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final reduced = reduceMotion || MediaQuery.disableAnimationsOf(context);
  owner?.setOpen(true);
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    return await showGeneralDialog<T>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      barrierLabel: '关闭弹层',
      barrierColor: Colors.transparent,
      transitionDuration: reduced ? Duration.zero : WenkuMotion.contact,
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          themes.wrap(
            GlassAppearance(
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
                    return CustomSingleChildLayout(
                      delegate: _GlassMenuPlacement(origin, safe, preferBelow),
                      child: _GlassMenuSurface(
                        child: Builder(builder: builder),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (reduced) return child;
        final curved = CurvedAnimation(
          parent: animation,
          curve: WenkuMotion.ease,
          reverseCurve: WenkuMotion.retract,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: .96, end: 1).animate(curved),
            alignment: Alignment.topCenter,
            child: child,
          ),
        );
      },
    );
  } finally {
    owner?.setOpen(false);
  }
}

class _GlassMenuSurface extends StatelessWidget {
  const _GlassMenuSurface({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    radius: 28,
    thickness: 20,
    elevated: false,
    // Panels contain several labels: soften the underlying text/controls so
    // they do not read as a second, stationary set of foreground glyphs.
    blur: math.min(12, GlassAppearance.of(context).blur),
    child: SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.all(8),
      child: child,
    ),
  );
}

/// Both the route and rendering fixtures use this same material/content split.
class GlassMenuItem extends StatelessWidget {
  const GlassMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.order = 0,
    this.icon,
  });
  final String label;
  final VoidCallback onPressed;
  final bool selected;
  final int order;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: JellyTapSurface(
      onTap: onPressed,
      haptic: HapticCue.selection,
      child: GlassForeground(
        child: ArchivePart(
          start: .06 + order.clamp(0, 8) * .025,
          end: .62 + order.clamp(0, 8) * .025,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .9)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
            ),
            child: Row(
              children: [
                if (icon != null)
                  ArchiveIcon(icon, size: 20)
                else
                  ExcludeSemantics(
                    child: SizedBox(
                      width: 3,
                      height: 3,
                      child: ColoredBox(
                        color: selected
                            ? Theme.of(context).colorScheme.surface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                SizedBox(width: icon == null ? 10 : 14),
                Expanded(
                  child: AppText(
                    label,
                    style: TextStyle(
                      color: selected
                          ? Theme.of(context).colorScheme.surface
                          : null,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected)
                  ArchiveIcon(
                    CupertinoIcons.check_mark,
                    size: 17,
                    color: Theme.of(context).colorScheme.surface,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The whole settings row is tappable; its actual glass selector is the menu's
/// source. Labels and controls share the same responsive layout in the reader.
class GlassSettingMenu<T> extends StatefulWidget {
  const GlassSettingMenu({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.reduceMotion,
    this.semanticLabel,
  });
  final IconData icon;
  final String label;
  final String? semanticLabel;
  final T value;
  final Map<T, String> options;
  final FutureOr<void> Function(T) onChanged;
  final bool reduceMotion;
  @override
  State<GlassSettingMenu<T>> createState() => _GlassSettingMenuState<T>();
}

class _GlassSettingMenuState<T> extends State<GlassSettingMenu<T>> {
  final _anchor = GlobalKey();
  bool _saving = false;
  Future<void> _open() async {
    if (_saving) return;
    final source = _anchor.currentContext;
    if (source == null) return;
    final selected = await showGlassMenu<T>(
      context: source,
      reduceMotion: widget.reduceMotion,
      builder: (menu) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, entry) in widget.options.entries.indexed)
              GlassMenuItem(
                order: index,
                label: entry.value,
                selected: entry.key == widget.value,
                onPressed: () => Navigator.pop(menu, entry.key),
              ),
          ],
        ),
      ),
    );
    if (mounted && selected != null && selected != widget.value) {
      setState(() => _saving = true);
      try {
        await widget.onChanged(selected);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = ArchivePart(
      start: .18,
      end: .84,
      child: Row(
        children: [
          ArchiveIcon(widget.icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: AppText(
              widget.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final selector = GlassMenuAnchor(
      child: Builder(
        key: _anchor,
        builder: (context) => LiquidGlass(
          radius: 20,
          elevated: false,
          semanticLabel: widget.semanticLabel ?? '选择${widget.label}',
          onTap: _saving ? null : _open,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: ArchivePart(
            start: .24,
            end: .88,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AppText(
                    widget.options[widget.value] ?? '',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 7),
                const ArchiveIcon(CupertinoIcons.chevron_down, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
    return JellyTapSurface(
      onTap: _saving ? null : _open,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          return constraints.maxWidth < 160 * scale + 70
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    label,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: selector),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 12),
                    // Short values use only their natural width instead of
                    // reserving two thirds of the row and wrapping its label.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .55,
                      ),
                      child: selector,
                    ),
                  ],
                );
        },
      ),
    );
  }
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
