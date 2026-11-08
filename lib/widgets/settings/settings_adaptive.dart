// Shared body vocabulary for the secondary settings surfaces: the local API
// console, logs, text replacement, system TTS, about, backup/import and
// reading statistics.
//
// Two presentations, one business body:
// - classic restores the pre-#291 vocabulary from fqapp-backup@f329399
//   (SettingsGroupCard / SettingsRow / SettingsSwitch / FilledButton /
//   OutlinedButton / HomeStateView / DataTransfer*).
// - archive keeps the Wenku8 rev ebcd7f1 surfaces #291 introduced
//   (ArchiveSection / ContentPanel / GlassTextButton / ContentNotice).
//
// Branches read [AppUiScope.isClassic], never the animated token value: a
// layout is decided once per selection, not from the in-between style
// `AnimatedTheme` produces mid-transition. Business state, persistence and
// result values stay in the pages; these widgets only choose a container. A
// page keeps one `State` and one body, so drafts, focus, in-flight saves and
// scroll targets survive a style switch.
//
// Geometry contract: classic rows carry their own 16dp horizontal padding
// (`SettingsRow`), archive rows sit inside `ContentPanel`'s 16dp padding, so
// [SettingsCard] never adds padding of its own. Rows with custom content wrap
// themselves in [SettingsCardRow], which supplies the classic padding and is a
// no-op under the archive panel.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../app_ui/app_ui_scope.dart';
import '../data_transfer_widgets.dart';
import '../home/home_design.dart';
import '../home/home_feed_states.dart';
import '../wenku/wenku_ui.dart';
import 'classic_settings_icons.dart';
import 'settings_widgets.dart';

/// Section title above a settings card.
///
/// Classic uses the home section header from f329399; archive keeps the
/// Wenku8 archive section (address code + rule line).
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.code,
    this.subtitle = '',
  });

  final String title;
  final String code;
  final String subtitle;

  @override
  Widget build(BuildContext context) => AppUiScope.isClassic(context)
      ? SettingsSectionHeader(title: title)
      : ArchiveSection(title: title, code: code, subtitle: subtitle);
}

/// A group of settings rows.
///
/// [children] must be net-zero horizontally: [SettingsRow] and
/// [SettingsActionRow]/[SettingsLinkRow] pad themselves in classic, and every
/// child is already inside `ContentPanel`'s padding in archive.
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.children,
    this.classicDividers = true,
    this.archiveDividers = true,
    this.dividerHeight = 22,
  });

  final List<Widget> children;

  /// Turn off for classic cards whose rows have no leading icon tile, where
  /// `SettingsGroupCard`'s 68dp-indented divider would not line up.
  final bool classicDividers;

  /// Turn off to keep an archive panel that had no hairlines before #292.
  final bool archiveDividers;

  final double dividerHeight;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return SettingsGroupCard(
        showDividers: classicDividers,
        children: children,
      );
    }
    return ContentPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0 && archiveDividers) Divider(height: dividerHeight),
            children[index],
          ],
        ],
      ),
    );
  }
}

/// Custom content inside a [SettingsCard]: padded like a settings row in
/// classic, untouched under the archive panel.
class SettingsCardRow extends StatelessWidget {
  const SettingsCardRow({
    super.key,
    required this.child,
    this.classicPadding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  final Widget child;
  final EdgeInsetsGeometry classicPadding;

  @override
  Widget build(BuildContext context) => AppUiScope.isClassic(context)
      ? Padding(padding: classicPadding, child: child)
      : child;
}

/// An in-card action: label only in archive (the Wenku8 `GlassTextButton`
/// vocabulary), icon/title/subtitle row in classic.
class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.icon,
    this.classicIcon,
    required this.title,
    this.subtitle,
    required this.onPressed,
    this.enabled = true,
    this.trailing,
  });

  /// Archive glyph; classic falls back to [classicSettingsIcon] or this value.
  final IconData icon;
  final IconData? classicIcon;
  final String title;
  final String? subtitle;
  final VoidCallback? onPressed;
  final bool enabled;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final action = enabled ? onPressed : null;
    if (!AppUiScope.isClassic(context)) {
      return GlassTextButton(onPressed: action, child: AppText(title));
    }
    return SettingsRow(
      icon: classicIcon ?? classicSettingsIcon(title, icon),
      iconTile: true,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      trailing: trailing,
      onTap: action,
    );
  }
}

/// Visual role of a [SettingsAction].
enum SettingsActionStyle { text, filled, outlined }

/// A standalone entry that owns its card: archive keeps the Wenku8
/// `FeatureEntry` panel, classic wraps one `SettingsRow` in a
/// `SettingsGroupCard` like the pre-#291 settings pages.
class SettingsEntryCard extends StatelessWidget {
  const SettingsEntryCard({
    super.key,
    required this.icon,
    this.classicIcon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  /// Archive glyph.
  final IconData icon;
  final IconData? classicIcon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final action = enabled ? onTap : null;
    if (AppUiScope.isClassic(context)) {
      return SettingsGroupCard(
        children: [
          SettingsRow(
            icon: classicIcon ?? classicSettingsIcon(title, icon),
            iconTile: true,
            title: title,
            subtitle: subtitle,
            enabled: enabled,
            onTap: action,
          ),
        ],
      );
    }
    return FeatureEntry(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: action,
    );
  }
}

/// A standalone button outside the row vocabulary.
///
/// Archive keeps the shared `GlassTextButton` (its label is what the current
/// pages show); classic picks the stock Material button the page used before
/// #291 so heights, radii and contrast match the rest of the classic UI.
class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.style = SettingsActionStyle.text,
    this.compact = false,
    this.muted = false,
    this.leftAligned = false,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final SettingsActionStyle style;

  /// Dense text action (toolbar-style), as used by the API console.
  final bool compact;

  /// Secondary text colour instead of the accent colour.
  final bool muted;

  /// Left-align text actions that act as disclosure toggles.
  final bool leftAligned;

  /// Fill the available width; classic uses the 50dp primary height then.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final action = onPressed;
    if (!AppUiScope.isClassic(context)) {
      return GlassTextButton(
        compact: compact,
        onPressed: action,
        child: AppText(label),
      );
    }
    final palette = HomePalette.of(context);
    final glyph = icon == null ? null : Icon(icon, size: 18);
    switch (style) {
      case SettingsActionStyle.text:
        final foreground = muted ? palette.muted : palette.accentText;
        if (leftAligned) {
          return Align(
            alignment: Alignment.centerLeft,
            child: glyph == null
                ? TextButton(
                    onPressed: action,
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(label),
                  )
                : TextButton.icon(
                    onPressed: action,
                    icon: Icon(icon, size: 16, color: foreground),
                    label: Text(label, style: TextStyle(color: foreground)),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      visualDensity: VisualDensity.compact,
                      foregroundColor: foreground,
                    ),
                  ),
          );
        }
        final textStyle = TextButton.styleFrom(
          foregroundColor: foreground,
          visualDensity: compact ? VisualDensity.compact : null,
          tapTargetSize: compact
              ? MaterialTapTargetSize.shrinkWrap
              : MaterialTapTargetSize.padded,
        );
        return glyph == null
            ? TextButton(
                onPressed: action,
                style: textStyle,
                child: Text(label),
              )
            : TextButton.icon(
                onPressed: action,
                icon: glyph,
                label: Text(label),
                style: textStyle,
              );
      case SettingsActionStyle.filled:
        final buttonStyle = FilledButton.styleFrom(
          backgroundColor: palette.accentText,
          foregroundColor: Colors.white,
          minimumSize: Size(expand ? double.infinity : 0, 50),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        );
        final button = glyph == null
            ? FilledButton(
                onPressed: action,
                style: buttonStyle,
                child: Text(label),
              )
            : FilledButton.icon(
                onPressed: action,
                style: buttonStyle,
                icon: glyph,
                label: Text(label),
              );
        return expand
            ? SizedBox(width: double.infinity, child: button)
            : button;
      case SettingsActionStyle.outlined:
        final buttonStyle = OutlinedButton.styleFrom(
          foregroundColor: palette.ink,
          side: BorderSide(color: palette.line),
          minimumSize: Size(expand ? double.infinity : 0, 46),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        );
        final button = glyph == null
            ? OutlinedButton(
                onPressed: action,
                style: buttonStyle,
                child: Text(label),
              )
            : OutlinedButton.icon(
                onPressed: action,
                style: buttonStyle,
                icon: glyph,
                label: Text(label),
              );
        return expand
            ? SizedBox(width: double.infinity, child: button)
            : button;
    }
  }
}

/// A collapsible block inside a [SettingsCard].
///
/// The expanded flag is **controlled** by the page State. A local flag would be
/// lost twice: `SettingsCard` switches between `SettingsGroupCard` and
/// `ContentPanel` (so the card's children are rebuilt into a new subtree), and a
/// list item scrolled out of the viewport is disposed entirely. Holding the
/// flag on the page keeps it across both.
///
/// Deliberately not `ExpansionTile`: that wraps a `ListTile`, and Flutter
/// animates `ListTile` text styles whenever `ListTileTheme` changes. Moving
/// between the classic theme (which defines one) and the archive `WenkuScope`
/// theme (which does not) makes `TextStyle.lerp` fail on mismatched `inherit`
/// values.
///
/// The height/chevron animation is driven by an explicit controller and
/// `SizeTransition`, not `AnimatedSize`: inside a list, an `AnimatedSize` whose
/// child changes height while it is being laid out asserts ("mutated in its own
/// performLayout"). Duration collapses to zero for reduced motion and e-ink.
class SettingsDisclosure extends StatefulWidget {
  const SettingsDisclosure({
    super.key,
    required this.title,
    required this.expanded,
    required this.onExpandedChanged,
    required this.children,
  });

  final String title;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;
  final List<Widget> children;

  static const duration = Duration(milliseconds: 180);

  @override
  State<SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<SettingsDisclosure>
    with SingleTickerProviderStateMixin {
  late final AnimationController _size = AnimationController(
    vsync: this,
    duration: SettingsDisclosure.duration,
    value: widget.expanded ? 1 : 0,
  )..addStatusListener(_onStatus);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _size.duration = _motionDuration;
  }

  @override
  void didUpdateWidget(SettingsDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;
    _size.duration = _motionDuration;
    if (widget.expanded) {
      _size.forward();
    } else {
      _size.reverse();
    }
  }

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  /// Rebuild once a collapse finishes so the closed body leaves the tree (and
  /// the semantics tree) instead of staying clipped at zero height.
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  Duration get _motionDuration {
    final reduce =
        MediaQuery.disableAnimationsOf(context) || HomePalette.of(context).eink;
    return reduce ? Duration.zero : SettingsDisclosure.duration;
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final palette = HomePalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = classic ? palette.muted : scheme.onSurfaceVariant;
    final body = Padding(
      padding: classic
          ? const EdgeInsets.fromLTRB(16, 0, 16, 12)
          : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.children,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: widget.expanded,
          child: InkWell(
            // InkWell maps ActivateIntent / ButtonActivateIntent, so Enter and
            // Space toggle the block once it has focus.
            onTap: () => widget.onExpandedChanged(!widget.expanded),
            child: Padding(
              // Classic rows own their 16dp gutter; the archive panel already
              // pads its content, so the header stays flush there.
              padding: classic
                  ? const EdgeInsets.fromLTRB(16, 12, 16, 12)
                  : const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: classic ? 15 : 14,
                        fontWeight: classic ? FontWeight.w600 : null,
                        color: classic ? palette.ink : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  RotationTransition(
                    turns: _size.drive(Tween<double>(begin: 0, end: .5)),
                    child: Icon(
                      LucideIcons.chevron_down,
                      size: 18,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ClipRect(
          child: SizeTransition(
            sizeFactor: _size,
            alignment: Alignment.topCenter,
            child: widget.expanded || _size.value > 0
                ? body
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }
}

/// Empty / error state.
///
/// Classic keeps `HomeStateView` (soft icon tile, accent action); archive keeps
/// `ContentNotice` (ambient archive glyph).
class SettingsNotice extends StatelessWidget {
  const SettingsNotice({
    super.key,
    required this.icon,
    this.classicIcon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  /// Archive glyph.
  final IconData icon;

  /// Classic glyph (Lucide); defaults to [icon].
  final IconData? classicIcon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return HomeStateView(
        icon: classicIcon ?? icon,
        title: title,
        message: message,
        actionLabel: actionLabel,
        actionIcon: actionLabel == null ? null : LucideIcons.refresh_cw,
        onAction: onAction,
      );
    }
    return ContentNotice(
      icon: icon,
      title: title,
      message: message,
      actionLabel: actionLabel ?? '重试',
      onRetry: onAction,
    );
  }
}

/// Inline result banner (import/backup outcome, or a failed read).
class SettingsMessage extends StatelessWidget {
  const SettingsMessage({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return DataTransferNotice(message: message, error: error);
    }
    if (error) return FeatureError(message);
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return ContentPanel(child: AppText(message, style: muted));
  }
}

/// Page-level heading used by the data pages (backup, 番茄 import).
class SettingsHeading extends StatelessWidget {
  const SettingsHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = LucideIcons.database,
  });

  final String title;
  final String subtitle;

  /// Classic header tile glyph; archive keeps the type-only heading.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return DataTransferHeader(icon: icon, title: title, subtitle: subtitle);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppText(
          title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        AppText(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Preview counters (backup/import totals).
///
/// Classic uses the soft stat chips from f329399; archive keeps the tabular
/// 72dp columns introduced by #291.
class SettingsStats extends StatelessWidget {
  const SettingsStats({super.key, required this.values});

  final Map<String, int> values;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return DataTransferStats(values: values);
    }
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Wrap(
      spacing: 14,
      runSpacing: 12,
      children: [
        for (final entry in values.entries)
          SizedBox(
            width: 72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(entry.key, style: muted),
                const SizedBox(height: 6),
                AppText(
                  '${entry.value}',
                  style: const TextStyle(
                    fontSize: 24,
                    height: 1.1,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -.6,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
