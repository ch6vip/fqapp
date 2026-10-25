import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/short_series_font_scale.dart';
import '../home/home_design.dart';
import 'player_side_panel.dart';

/// 横屏字号面板：与选集抽屉同宽同高的右侧面板，三档列表 + 样张。
///
/// 底部弹层挪到右侧 240–420dp 的面板里会被拉成一条稀疏的横排，三档药丸
/// 和预览文字挤在一行；这里改成整行档位 + 底部样张，选档即时生效、面板
/// 不关（预览要留在原地对比）。✕ 回 `pop(PlayerSidePanelRoute.more)`，
/// 由宿主落回视频设置。
class PlayletFontScaleSidePanel extends StatefulWidget {
  const PlayletFontScaleSidePanel({super.key, this.onSelected, this.onBack});

  /// 每次选档后回调，宿主用它刷新自己树里的文字缩放。
  final VoidCallback? onSelected;

  /// ✕ 的行为。嵌在视频设置栈里时传「回上一层」，独立路由时默认 pop 回
  /// `PlayerSidePanelRoute.more`。
  final VoidCallback? onBack;

  @override
  State<PlayletFontScaleSidePanel> createState() =>
      _PlayletFontScaleSidePanelState();
}

class _PlayletFontScaleSidePanelState extends State<PlayletFontScaleSidePanel> {
  /// 面板自己的取值：`ShortSeriesFontScale.instance` 在宿主树里刷新，
  /// 这里读一次快照 + 本地更新，避免依赖宿主的 setState。
  late int _current = ShortSeriesFontScale.instance.clamp(0, 2);

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return SafeArea(
      // 面板贴右缘：左边那条安全区属于屏幕另一侧，让开会把整列右推。
      left: false,
      child: Column(
        key: const ValueKey('player-font-scale-panel'),
        children: [
          PlayerSidePanelHeader(
            title: '字体大小',
            onClose:
                widget.onBack ??
                () => Navigator.pop(context, PlayerSidePanelRoute.more),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              children: [
                for (final (index, label)
                    in ShortSeriesFontScale.labels.indexed)
                  InkWell(
                    key: ValueKey('player-font-scale-$index'),
                    onTap: () {
                      unawaited(ShortSeriesFontScale.save(index));
                      widget.onSelected?.call();
                      setState(() => _current = index);
                    },
                    child: SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: index == _current
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: index == _current
                                      ? PlayerSidePanelRow.accent
                                      : Colors.white,
                                ),
                              ),
                            ),
                            if (index == _current)
                              const Icon(
                                Icons.check,
                                size: 18,
                                color: PlayerSidePanelRow.accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 样张按选中档即时缩放（官方 ShortSeriesScaleTextView 语义）。
          Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12 + bottom),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '播放页文字大小预览',
                key: const ValueKey('player-font-scale-preview'),
                textScaler: TextScaler.linear(ShortSeriesFontScale.scale),
                style: const TextStyle(fontSize: 14, color: Color(0xCCFFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 字号弹层（官方 `nm3.e`）：标准/大号/超大号三档药丸 + 选中档的预览
/// 文本（官方是 `ShortSeriesScaleTextView` 样张）。选中即生效并持久化
/// （SP `short_series_font_scale_manager/current_selected_index`）。
///
/// 播放页 chrome 与短剧 feed 的更多面板「字体大小」行共用这一张弹层；
/// 弹层自身的打开时机（面板收起后级联、`_modalOpen` 计账）由宿主管理。
/// [onSelected] 在每次选档后回调，宿主用它刷新自己树里的文字缩放
/// （chrome 的 TextScaler 即时生效；feed 的卡面文字不参与缩放，可不传）。
/// Note: 字号档作用域/弹幕豁免/弹层不自动关的取舍 — 见
/// .agents/notes/implemented/feature/2026-09-29-listen-mode-and-font-scale.md
Future<void> showPlayletFontScaleSheet(
  BuildContext context, {
  VoidCallback? onSelected,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  sheetAnimationStyle: const AnimationStyle(
    duration: Duration(milliseconds: 200),
    reverseDuration: Duration(milliseconds: 200),
  ),
  barrierColor: Colors.transparent,
  // 深色 / OLED 弹层取 surface + 发丝边：与听书/评论弹层同一规则。
  backgroundColor: homeSheetColor(HomePalette.of(context)),
  shape: homeSheetShape(HomePalette.of(context), top: 16),
  builder: (sheetContext) => StatefulBuilder(
    builder: (sheetContext, setSheetState) {
      final palette = HomePalette.of(sheetContext);
      final current = ShortSeriesFontScale.instance.clamp(0, 2);
      return SafeArea(
        top: false,
        child: Padding(
          key: const ValueKey('player-font-scale-sheet'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '字体大小',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final (index, label)
                      in ShortSeriesFontScale.labels.indexed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Semantics(
                        label: label,
                        button: true,
                        selected: index == current,
                        onTap: () {},
                        excludeSemantics: true,
                        child: InkWell(
                          key: ValueKey('player-font-scale-$index'),
                          onTap: () {
                            unawaited(ShortSeriesFontScale.save(index));
                            onSelected?.call();
                            setSheetState(() {});
                          },
                          borderRadius: BorderRadius.circular(15),
                          child: Container(
                            height: 30,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              // 选中档在深色下用 line 抬高一层，浅色仍是白药丸。
                              color: index == current
                                  ? (palette.dark ? palette.line : Colors.white)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: index == current
                                    ? (palette.dark
                                          ? palette.line
                                          : const Color(0x1F000000))
                                    : Colors.transparent,
                              ),
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: index == current
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: index == current
                                    ? palette.ink
                                    : palette.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // 预览行按选中档即时缩放（官方样张语义）。
              Text(
                '播放页文字大小预览',
                key: const ValueKey('player-font-scale-preview'),
                textScaler: TextScaler.linear(ShortSeriesFontScale.scale),
                style: TextStyle(fontSize: 14, color: palette.ink),
              ),
            ],
          ),
        ),
      );
    },
  ),
);
