// Restored from fqapp-backup@f329399 (issue #288), RootShell bottom navigation.
// Only presentation is copied; selection and the retained tabs stay in RootShell.
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_theme.dart';
import 'home/home_design.dart';

class ClassicShellDock extends StatelessWidget {
  const ClassicShellDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.overVideo,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool overVideo;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final glassDark = palette.dark || overVideo;
    final eink = einkModeNotifier.value;
    final oled = oledActive();
    final navBar = NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: eink
            ? Colors.black
            : HomePalette.accent.withValues(alpha: glassDark ? .20 : .12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? (eink ? Colors.white : HomePalette.accent)
                : (eink
                      ? Colors.black
                      : glassDark
                      ? Colors.white.withValues(alpha: .65)
                      : palette.muted),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (eink
                      ? Colors.black
                      : glassDark
                      ? HomePalette.accent
                      : palette.accentText)
                : (eink
                      ? Colors.black
                      : glassDark
                      ? Colors.white.withValues(alpha: .65)
                      : palette.muted),
          ),
        ),
      ),
      child: NavigationBar(
        key: const ValueKey('classic-navigation-bar'),
        selectedIndex: selectedIndex,
        onDestinationSelected: onSelected,
        backgroundColor: Colors.transparent,
        elevation: 0,
        destinations: const [
          NavigationDestination(
            icon: Icon(LucideIcons.house),
            selectedIcon: Icon(LucideIcons.house),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.clapperboard),
            selectedIcon: Icon(LucideIcons.clapperboard),
            label: '短剧',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.library_big),
            selectedIcon: Icon(LucideIcons.library_big),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(LucideIcons.circle_user_round),
            selectedIcon: Icon(LucideIcons.circle_user_round),
            label: '我的',
          ),
        ],
      ),
    );
    final staticBar = Container(
      decoration: BoxDecoration(
        color: oled
            ? const Color(0xFF0C0C0E)
            : glassDark
            ? const Color(0xFF161619).withValues(alpha: .72)
            : Colors.white.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: glassDark
              ? Colors.white.withValues(alpha: .16)
              : Colors.white.withValues(alpha: .75),
          width: .8,
        ),
      ),
      child: navBar,
    );
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: RepaintBoundary(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: eink
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: glassDark ? .38 : .08,
                        ),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: HomePalette.accent.withValues(
                          alpha: glassDark ? .06 : .03,
                        ),
                        blurRadius: 14,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: eink
                  ? Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: Colors.black, width: .8),
                      ),
                      child: navBar,
                    )
                  : selectedIndex == 1 || oled
                  ? staticBar
                  : BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: staticBar,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
