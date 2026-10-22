import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/short_series_font_scale.dart';
import '../home/home_design.dart';

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
}) =>
    showModalBottomSheet<void>(
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
                      for (final (index, label) in ShortSeriesFontScale.labels
                          .indexed)
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  // 选中档在深色下用 line 抬高一层，浅色仍是白药丸。
                                  color: index == current
                                      ? (palette.dark
                                            ? palette.line
                                            : Colors.white)
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
