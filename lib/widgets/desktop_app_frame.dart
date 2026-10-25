import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../services/desktop_platform.dart';

final desktopTab = ValueNotifier<int>(0);

class DesktopAppFrame extends StatelessWidget {
  const DesktopAppFrame({super.key, required this.child});
  final Widget child;
  void _select(int index) {
    DesktopPlatform.navigatorKey.currentState?.popUntil(
      (route) => route.isFirst,
    );
    desktopTab.value = index;
  }

  void _search(String query) {
    DesktopPlatform.navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPage(initialQuery: query.isEmpty ? null : query),
      ),
    );
  }

  @override
  // MaterialApp.builder is above its Navigator. The frame's own tooltips need
  // an overlay here; the page Navigator below cannot host a sibling's tooltip.
  Widget build(BuildContext context) => Overlay.wrap(
    child: ValueListenableBuilder<bool>(
      valueListenable: DesktopPlatform.fullscreen,
      builder: (context, full, _) {
        if (full) return child;
        final theme = Theme.of(context);
        return Material(
          color: theme.scaffoldBackgroundColor,
          child: Row(
            children: [
              ValueListenableBuilder<int>(
                valueListenable: desktopTab,
                builder: (context, index, _) => NavigationRail(
                  key: const Key('desktop-navigation'),
                  selectedIndex: index,
                  onDestinationSelected: _select,
                  backgroundColor: theme.colorScheme.surface,
                  minWidth: 76,
                  trailingAtBottom: true,
                  trailing: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: IconButton(
                      key: const Key('desktop-settings'),
                      tooltip: '设置',
                      icon: const Icon(LucideIcons.settings),
                      onPressed: () =>
                          DesktopPlatform.navigatorKey.currentState?.push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SettingsPage(),
                            ),
                          ),
                    ),
                  ),
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: ClipRRect(
                      // Same plate radius as the about page logo (15%).
                      borderRadius: BorderRadius.circular(7),
                      child: Image.asset(
                        'assets/images/app_logo.webp',
                        width: 44,
                        height: 44,
                      ),
                    ),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(LucideIcons.house),
                      label: Text('首页'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(LucideIcons.clapperboard),
                      label: Text('短剧'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(LucideIcons.library_big),
                      label: Text('书架'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(LucideIcons.circle_user_round),
                      label: Text('我的'),
                    ),
                  ],
                ),
              ),
              VerticalDivider(
                width: 1,
                color: theme.dividerColor.withValues(alpha: .15),
              ),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        border: Border(
                          bottom: BorderSide(
                            color: theme.dividerColor.withValues(alpha: .12),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '返回',
                            onPressed: () => DesktopPlatform
                                .navigatorKey
                                .currentState
                                ?.maybePop(),
                            icon: const Icon(LucideIcons.arrow_left, size: 20),
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '什锦铺',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            // 短剧分区自带搜索入口（频道条的搜索图标，按
                            // 短剧名或主演名搜），壳层全局搜索在该分区
                            // 隐藏，避免两个搜索框上下叠排挤占视频空间；
                            // 其它分区没有自己的搜索行，仍用全局搜索。
                            child: ValueListenableBuilder<int>(
                              valueListenable: desktopTab,
                              builder: (context, tab, _) => tab == 1
                                  ? const SizedBox.shrink()
                                  : Align(
                                      alignment: Alignment.centerRight,
                                      child: SizedBox(
                                        width: 440,
                                        child: TextField(
                                          key: const Key('desktop-search'),
                                          onSubmitted: _search,
                                          textInputAction:
                                              TextInputAction.search,
                                          decoration: InputDecoration(
                                            hintText:
                                                '搜索小说、短剧、漫画、听书 / 作品 ID',
                                            isDense: true,
                                            prefixIcon: const Icon(
                                              LucideIcons.search,
                                              size: 18,
                                            ),
                                            filled: true,
                                            fillColor:
                                                theme.scaffoldBackgroundColor,
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(24),
                                              borderSide: BorderSide.none,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: child),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
