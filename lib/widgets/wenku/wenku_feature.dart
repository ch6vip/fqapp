import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/app_style_tokens.dart';

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';

class ArchiveFeaturePage extends StatelessWidget {
  const ArchiveFeaturePage({
    super.key,
    required this.title,
    required this.code,
    required this.child,
    this.actions = const [],
    this.canPop = true,
  });

  final String title;
  final String code;
  final Widget child;
  final List<Widget> actions;
  final bool canPop;

  @override
  Widget build(BuildContext context) => WenkuPage(
    header: ArchiveHeaderBar(
      leading: GlassIconButton(
        icon: CupertinoIcons.back,
        label: '返回',
        onPressed: canPop ? () => Navigator.pop(context) : null,
      ),
      title: ArchiveRouteTitle(title: title, code: code),
      actions: actions,
    ),
    child: child,
  );
}

EdgeInsets featurePadding(BuildContext context) => EdgeInsets.fromLTRB(
  AppStyleTokens.of(context).pageGutter,
  MediaQuery.paddingOf(context).top +
      FrostedHeader.toolbarHeight +
      (AppStyleTokens.of(context).isClassic ? 12 : 20),
  AppStyleTokens.of(context).pageGutter,
  MediaQuery.paddingOf(context).bottom + 32,
);

class FeatureEntry extends StatelessWidget {
  const FeatureEntry({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.trailingText,
  });

  final String title;
  final String? subtitle;

  /// A widget pinned to the trailing edge, before the chevron.
  final Widget? trailing;

  /// A short value shown next to the chevron — the current setting, say.
  ///
  /// This is separate from [trailing] because the two sit in different
  /// places: the value belongs *with* the chevron, both pinned to the
  /// trailing edge, while [trailing] is a control that sits before them.
  /// Putting a value into [trailing] pushed the chevron left and let a long
  /// value squeeze it, so the one row that had a value ended up with its
  /// arrow in a different place than every other row.
  final String? trailingText;

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ContentPanel(
    onTap: onTap,
    child: ArchivePart(
      start: .18,
      end: .84,
      travel: const Offset(0, 6),
      child: Row(
        children: [
          ArchiveIcon(icon, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 5),
                  AppText(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // The value and the chevron are one trailing group. The value used
          // to be a loose `Flexible` whose text took its natural width, and
          // the chevron sat right next to it instead of at the row edge -
          // the one row that showed a value had its arrow somewhere else than
          // every other row. The group is a tight `Expanded` that ends its
          // content at the trailing edge, so the chevron always sits at the
          // same x; the title keeps its own `Expanded` share.
          if (trailing != null || trailingText != null)
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (trailing != null) ...[
                    Flexible(child: trailing!),
                    const SizedBox(width: 8),
                  ],
                  if (trailingText != null)
                    Flexible(
                      fit: FlexFit.tight,
                      child: AppText(
                        trailingText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
                ],
              ),
            )
          else ...[
            const SizedBox(width: 8),
            const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
          ],
        ],
      ),
    ),
  );
}

class FeatureError extends StatelessWidget {
  const FeatureError(this.text, {super.key});

  final String? text;

  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Semantics(
            liveRegion: true,
            child: AppText(
              text!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        );
}
