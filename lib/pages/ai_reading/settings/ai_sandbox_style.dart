import 'package:flutter/material.dart';

import '../../../widgets/app_ui/app_ui_scope.dart';
import '../../../widgets/home/home_design.dart';

/// The console prototype's tokens, scoped to its routes and local editor.
class AiSandboxStyle {
  AiSandboxStyle(BuildContext context)
    : palette = HomePalette.of(context),
      classic = AppUiScope.isClassic(context);

  final HomePalette palette;
  final bool classic;
  Color get line => palette.eink
      ? Colors.black
      : classic && palette.dark
      ? const Color(0xFF3B3B40)
      : palette.line;
  Color get soft => classic && palette.dark && !palette.eink
      ? const Color(0xFF303034)
      : palette.soft;
  Color get accent => palette.eink
      ? Colors.black
      : palette.dark
      ? const Color(0xFFFF9C86)
      : HomePalette.accentStrong;
  Color get primary => palette.eink
      ? Colors.black
      : palette.dark
      ? const Color(0xFFF7755D)
      : HomePalette.accent;
  Color get error => palette.eink
      ? Colors.black
      : palette.dark
      ? const Color(0xFFFFB4AB)
      : const Color(0xFFBA1A1A);
  Color get success => palette.eink
      ? Colors.black
      : palette.dark
      ? const Color(0xFF8DD6AA)
      : const Color(0xFF28724B);
  Color get highlight => palette.eink
      ? Colors.white
      : palette.dark
      ? const Color(0xFF52332D)
      : const Color(0xFFFFEBE4);
  double get editorRadius => classic ? 12 : 4;

  ButtonStyle textButton({bool muted = false, double size = 13}) =>
      TextButton.styleFrom(
        foregroundColor: muted ? palette.muted : accent,
        minimumSize: const Size(48, 42),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        textStyle: TextStyle(
          fontSize: size,
          fontWeight: muted ? FontWeight.normal : FontWeight.w500,
        ),
      );

  ButtonStyle get runButton => FilledButton.styleFrom(
    backgroundColor: primary,
    foregroundColor: palette.dark && !palette.eink
        ? const Color(0xFF251B18)
        : Colors.white,
    minimumSize: const Size(48, 46),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  );

  ButtonStyle get stopButton => OutlinedButton.styleFrom(
    foregroundColor: error,
    backgroundColor: palette.surface,
    side: BorderSide(color: line),
    minimumSize: const Size(48, 46),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    textStyle: const TextStyle(fontSize: 14),
  );
}

class AiSandboxPanel extends StatelessWidget {
  const AiSandboxPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.raw = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final bool raw;

  @override
  Widget build(BuildContext context) {
    final style = AiSandboxStyle(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: style.palette.surface,
        border: Border.all(color: style.line),
        borderRadius: BorderRadius.circular(
          raw && style.classic ? 10 : style.editorRadius,
        ),
      ),
      child: child,
    );
  }
}

/// Material tabs retain keyboard navigation and selected-state semantics.
class AiSandboxTabs extends StatelessWidget {
  const AiSandboxTabs({super.key, required this.labels, this.onTap});
  final List<String> labels;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final style = AiSandboxStyle(context);
    return TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: EdgeInsets.zero,
      labelPadding: const EdgeInsets.only(right: 18),
      indicatorPadding: const EdgeInsets.only(right: 18),
      indicatorSize: TabBarIndicatorSize.tab,
      indicatorColor: style.primary,
      indicatorWeight: 2,
      dividerColor: style.line,
      dividerHeight: 1,
      labelColor: style.accent,
      unselectedLabelColor: style.palette.muted,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      unselectedLabelStyle: const TextStyle(fontSize: 13),
      onTap: onTap,
      tabs: [for (final label in labels) Tab(text: label, height: 42)],
    );
  }
}
