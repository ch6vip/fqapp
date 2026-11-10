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
///
/// The body extends behind the opaque AppBar on purpose: pages still use
/// [featurePadding]'s archive header clearance, which then lands one gutter
/// below the AppBar instead of being counted twice. A page that brings its own
/// zero top inset must start below the AppBar itself.
class ClassicFeaturePage extends StatelessWidget {
  const ClassicFeaturePage({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
    this.bottomNavigationBar,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  /// Fixed action bar for pages whose pre-#291 layout pinned its primary
  /// action (text replacement, backup, 番茄 import). The archive presentation
  /// keeps those actions inside the page instead.
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: title,
    actions: actions.isEmpty ? null : actions,
    bottomNavigationBar: bottomNavigationBar,
    // A single embedded route must not offer a back affordance that would pop
    // the only page blank (Windows two-pane settings).
    showBack: Navigator.of(context).canPop(),
    // Pages migrated later still use featurePadding's archive header
    // clearance; extending behind the opaque AppBar keeps that clearance from
    // being counted twice (first row stays 12dp below the AppBar).
    extendBodyBehindAppBar: true,
    body: child,
  );
}

/// Selects the shared business page's chrome for the live style.
///
/// The page content keeps one element (and State) across the shell switch: the
/// state holds a stable [GlobalKey] above the shell branch, so an open draft,
/// focus or scroll position is not re-inflated with the new header.
class AppFeaturePage extends StatefulWidget {
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
  State<AppFeaturePage> createState() => _AppFeaturePageState();
}

class _AppFeaturePageState extends State<AppFeaturePage> {
  /// Owned above the shell branch: the child's Element moves between shells
  /// instead of being recreated.
  final _contentKey = GlobalKey(debugLabel: 'app-feature-content');

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (AppUiScope.isClassic(context)) {
      return ClassicFeaturePage(
        title: widget.title,
        actions: widget.actions,
        child: content,
      );
    }
    return ArchiveFeaturePage(
      title: widget.title,
      code: widget.code,
      actions: widget.actions,
      canPop: widget.canPop ?? Navigator.of(context).canPop(),
      child: content,
    );
  }
}

/// Clearance for the floating archive header used by `WenkuPage` /
/// `ArchiveFeaturePage`: status bar + toolbar height + the style's extra gap.
///
/// [ClassicFeaturePage] extends its body behind the opaque AppBar, so a page
/// that keeps using this padding lands 12dp below the classic AppBar instead
/// of reserving the header height twice.
///
/// The gutter and gap come from the **discrete** style when [AppUiScope] is
/// above the page, not from the interpolated `AppStyleTokens` the animated
/// theme reports mid-transition: a padding that lerps would move the whole
/// list while a style switch is animating, and a scroll anchor restored at the
/// start of that animation would end up a few pixels off.
EdgeInsets featurePadding(BuildContext context) {
  final tokens = AppUiScope.isAvailable(context)
      ? AppUiScope.presentationOf(context).tokens
      : AppStyleTokens.of(context);
  return EdgeInsets.fromLTRB(
    tokens.pageGutter,
    MediaQuery.paddingOf(context).top +
        FrostedHeader.toolbarHeight +
        (tokens.isClassic ? 12 : 20),
    tokens.pageGutter,
    MediaQuery.paddingOf(context).bottom + 32,
  );
}

/// Height of the floating archive header that is painted *over* the page body
/// (`WenkuPage` / `ArchiveFeaturePage`): status bar + glass toolbar.
///
/// The scroll viewport starts at the very top of the screen in those shells, so
/// this is the distance from its top edge to the first row that is not under
/// the glass bar. Content anchors use it instead of the raw viewport edge; the
/// classic shell puts its Material AppBar above the body, where the inset is 0.
double archiveChromeInset(BuildContext context) {
  final padding = MediaQuery.paddingOf(context);
  final viewPadding = MediaQuery.viewPaddingOf(context);
  final status = padding.top > viewPadding.top ? padding.top : viewPadding.top;
  return status + FrostedHeader.toolbarHeight;
}

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
