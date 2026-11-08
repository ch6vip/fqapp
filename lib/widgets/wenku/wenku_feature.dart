import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../services/app_style_tokens.dart';
import '../app_ui/app_ui_scope.dart';
import '../settings/settings_widgets.dart';

import 'src/app_text.dart';
import 'wenku_archive.dart';
import 'wenku_glass.dart';
import 'wenku_icons.dart';

/// Archive feature page: milk paper, address code and the glass back affordance.
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

/// Classic feature page: the original settings-style shell (canvas AppBar, no
/// archive masthead/code/backdrop) around the same business body.
///
/// The back affordance follows the nearest Navigator: a single embedded route
/// (the Windows two-pane settings Navigator) keeps its content instead of
/// popping itself blank.
class ClassicFeaturePage extends StatelessWidget {
  const ClassicFeaturePage({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: title,
    actions: actions.isEmpty ? null : actions,
    // A single embedded route must not offer a back affordance that would pop
    // the only page blank (Windows two-pane settings).
    showBack: Navigator.of(context).canPop(),
    body: child,
  );
}

/// Selects the shared business page's chrome for the live style.
///
/// The page content stays the same widget and State; only the header/shell
/// changes. Existing call sites are migrated one by one (`ArchiveFeaturePage`
/// and `SettingsArchivePage` stay available for their archive shapes).
class AppFeaturePage extends StatelessWidget {
  const AppFeaturePage({
    super.key,
    required this.title,
    required this.code,
    required this.child,
    this.actions = const [],
    this.canPop,
  });

  final String title;
  final String code;
  final Widget child;
  final List<Widget> actions;

  /// Archive shell override; the classic shell derives this from the nearest
  /// Navigator (see [ClassicFeaturePage]).
  final bool? canPop;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return ClassicFeaturePage(title: title, actions: actions, child: child);
    }
    return ArchiveFeaturePage(
      title: title,
      code: code,
      actions: actions,
      canPop: canPop ?? Navigator.of(context).canPop(),
      child: child,
    );
  }
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
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
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
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Flexible(child: trailing!),
          ],
          const SizedBox(width: 8),
          const ArchiveIcon(CupertinoIcons.chevron_right, size: 14),
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
