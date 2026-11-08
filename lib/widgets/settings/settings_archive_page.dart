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
class SettingsArchivePage extends StatelessWidget {
  const SettingsArchivePage({
    super.key,
    required this.title,
    required this.code,
    required this.child,
    this.actions = const [],
  });

  final String title;
  final String code;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (AppUiScope.isClassic(context)) {
      return ClassicFeaturePage(title: title, actions: actions, child: child);
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
        title: ArchiveRouteTitle(title: title, code: code),
        actions: actions,
      ),
      child: child,
    );
  }
}
