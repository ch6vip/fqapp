// Archive feature page for settings surfaces that can also render inside the
// Windows two-pane settings shell.
//
// Ported chrome follows Wenku8_Flutter (revision ebcd7f1) `ArchiveFeaturePage`
// (`lib/app_ui.dart`): WenkuPage + ArchiveHeaderBar with a glass back button
// and an ArchiveRouteTitle.
//
// fqapp adaptation:
// - The shell follows the live style: archive keeps this Wenku header, classic
//   reuses the original canvas AppBar via [ClassicFeaturePage]. Both branches
//   keep the same child and State.
// - `DesktopSettingsBody` mounts each category page in a nested Navigator that
//   holds exactly one route. `ArchiveFeaturePage` always pops, so pressing its
//   back button there removed the only route and left the right pane blank.
//   Here the back affordance is rendered only when the nearest Navigator can
//   actually pop; the embedded (desktop) pane therefore keeps its content and
//   switches categories from the sidebar instead. The classic shell derives the
//   same check from the nearest Navigator.
// - `Navigator.maybePop` replaces `Navigator.pop` for the same reason: a stale
//   tap on a surface that cannot pop is a no-op.

import 'package:flutter/cupertino.dart';

import '../app_ui/app_ui_scope.dart';
import '../wenku/wenku_ui.dart';

/// [ArchiveFeaturePage] with a back affordance only when there is something
/// to pop, and the classic feature shell for the classic style.
///
/// The content keeps one element (and State) across a style switch: the state
/// owns a [GlobalKey] above the shell branch, so an open draft, focus or scroll
/// position survives archive -> classic -> archive.
class SettingsArchivePage extends StatefulWidget {
  const SettingsArchivePage({
    super.key,
    required this.title,
    required this.code,
    required this.child,
    this.actions = const [],
    this.classicBottomBar,
  });

  final String title;
  final String code;
  final Widget child;
  final List<Widget> actions;

  /// Fixed action bar for the classic shell only. Pages that used to pin their
  /// primary action (text replacement, backup, 番茄 import) pass it here so both
  /// presentations can keep **one** body tree; otherwise switching the shell
  /// would dispose the list and its scroll position. The archive shell ignores
  /// it because those pages render their actions inside the page.
  final Widget? classicBottomBar;

  @override
  State<SettingsArchivePage> createState() => _SettingsArchivePageState();
}

class _SettingsArchivePageState extends State<SettingsArchivePage> {
  final _contentKey = GlobalKey(debugLabel: 'settings-archive-content');

  @override
  Widget build(BuildContext context) {
    final content = KeyedSubtree(key: _contentKey, child: widget.child);
    if (AppUiScope.isClassic(context)) {
      return ClassicFeaturePage(
        title: widget.title,
        actions: widget.actions,
        bottomNavigationBar: widget.classicBottomBar,
        child: content,
      );
    }
    final canPop = Navigator.of(context).canPop();
    return WenkuPage(
      header: ArchiveHeaderBar(
        leading: canPop
            ? GlassIconButton(
                icon: CupertinoIcons.back,
                label: '返回',
                onPressed: () => Navigator.maybePop(context),
              )
            : const SizedBox.shrink(),
        title: ArchiveRouteTitle(title: widget.title, code: widget.code),
        actions: widget.actions,
      ),
      child: content,
    );
  }
}
