import 'package:flutter/material.dart';

import '../../services/episode_source_cache.dart';
import '../../services/playback_format.dart';
import '../../services/player_preferences.dart';

/// 竖屏底栏「倍速」「清晰度」的档位弹层。
///
/// 这两项不再放进「视频设置」：底栏右下角已经写着当前档，点它要的是换档，
/// 不是再进一层设置列表。横屏同款入口走右侧面板
/// （[PlayerSidePanelOptionList]），这里只管竖屏的底部弹层。
///
/// 选中即 `pop(值)` 并收起，由宿主落地（倍速 `_applyRate` / 清晰度
/// `onQualitySelected`），与横屏档位面板同语义。
Future<double?> showPlayletRateSheet(
  BuildContext context, {
  required double rate,
  bool dark = true,
}) => _showOptionSheet<double>(
  context,
  dark: dark,
  child: PlayletOptionSheet<double>(
    sheetKey: 'player-rate-sheet',
    title: '倍速',
    dark: dark,
    isSelected: (value) => value == rate,
    options: [
      for (final value in PlayerPreferences.playbackRates)
        PlayletOption(
          // 档位文案用 chip 形（1x 而不是底栏上的「倍速」）。
          label: '${formatPlaybackRate(value)}x',
          value: value,
        ),
    ],
  ),
);

Future<EpisodeVariant?> showPlayletQualitySheet(
  BuildContext context, {
  required List<EpisodeVariant> variants,
  String? currentUrl,
  bool dark = true,
}) => _showOptionSheet<EpisodeVariant>(
  context,
  dark: dark,
  child: PlayletOptionSheet<EpisodeVariant>(
    sheetKey: 'player-quality-sheet',
    title: '清晰度',
    dark: dark,
    isSelected: (variant) => variant.url == currentUrl,
    options: [
      for (final variant in variants)
        PlayletOption(label: variant.name, value: variant),
    ],
  ),
);

Future<T?> _showOptionSheet<T>(
  BuildContext context, {
  required bool dark,
  required Widget child,
}) => showModalBottomSheet<T>(
  context: context,
  useSafeArea: true,
  backgroundColor: dark ? const Color(0xFF1C1C1C) : const Color(0xFFFAFAFA),
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(dark ? 12 : 16)),
  ),
  builder: (_) => child,
);

/// 档位弹层本体：拖拽手柄 + 居中标题 + 单选行。
///
/// 行高 48dp、选中档品牌橙 + 对勾；档位多的（清晰度三档以上）在弹层高度
/// 内可滚，不会把弹层撑到盖住整屏。
class PlayletOptionSheet<T> extends StatelessWidget {
  const PlayletOptionSheet({
    super.key,
    required this.title,
    required this.options,
    required this.isSelected,
    required this.sheetKey,
    this.dark = true,
  });

  final String title;
  final List<PlayletOption<T>> options;
  final bool Function(T value) isSelected;

  /// 弹层根 key（`player-rate-sheet` / `player-quality-sheet`）与档位 key
  /// 前缀：档位渲染成 `ValueKey('$sheetKey-$index')`。
  final String sheetKey;

  /// 深色（`#1C1C1C`）或浅色（`#FAFAFA`）皮肤，与视频设置面板同源。
  final bool dark;

  static const _accent = Color(0xFFFA6725);

  Color get _foreground => dark ? Colors.white : const Color(0xFF000000);

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      key: ValueKey(sheetKey),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: const ValueKey('player-option-drag-handle'),
          height: 20,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: dark ? const Color(0x33FFFFFF) : const Color(0x1F000000),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _foreground,
              ),
            ),
          ),
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              final selected = isSelected(option.value);
              return InkWell(
                key: ValueKey('$sheetKey-$index'),
                onTap: () => Navigator.pop(context, option.value),
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            option.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              color: selected ? _accent : _foreground,
                            ),
                          ),
                        ),
                        if (selected)
                          const Icon(Icons.check, size: 18, color: _accent),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

/// 档位弹层的一项。
class PlayletOption<T> {
  const PlayletOption({required this.label, required this.value});

  final String label;
  final T value;
}
