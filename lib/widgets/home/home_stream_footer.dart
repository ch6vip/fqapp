import 'package:flutter/material.dart';

import 'home_design.dart';

/// The card stream's tail (`aes.xml` + `widget/u4.java`, footer type 199).
///
/// Three states, all 12sp [HomePalette.muted]:
/// loading「加载中...」/ retry「加载失败，点击重试」(tap reloads) /
/// done「已经到底了」— the done form sits between two 12×0.5dp rules
/// with 8dp top / 32dp bottom padding; the others take 16dp top / 24dp
/// bottom (`vu`)。
///
/// 重试整行可点且触控高度不小于 44dp；[includeBottomSafeArea] 为 true 时
/// 底部再加上系统手势条安全区（直接铺在页面底部的列表用它）。
class HomeStreamFooter extends StatelessWidget {
  const HomeStreamFooter.loading({
    super.key,
    this.onRetry,
    this.includeBottomSafeArea = false,
  }) : _state = _StreamFooterState.loading;

  const HomeStreamFooter.retry({
    super.key,
    required this.onRetry,
    this.includeBottomSafeArea = false,
  }) : _state = _StreamFooterState.retry;

  const HomeStreamFooter.done({
    super.key,
    this.onRetry,
    this.includeBottomSafeArea = false,
  }) : _state = _StreamFooterState.done;

  final _StreamFooterState _state;
  final VoidCallback? onRetry;
  final bool includeBottomSafeArea;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final color = palette.muted;
    final safeBottom = includeBottomSafeArea
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;
    switch (_state) {
      case _StreamFooterState.done:
        return Padding(
          padding: EdgeInsets.only(top: 8, bottom: 32 + safeBottom),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 档案式细线：1dp 实线 + 等宽留白，和分区标签同一种收尾。
              Container(width: 18, height: 1, color: palette.line),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '已经到底了',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    letterSpacing: 0.3,
                    color: color,
                  ),
                ),
              ),
              Container(width: 18, height: 1, color: palette.line),
            ],
          ),
        );
      case _StreamFooterState.retry:
        return Padding(
          padding: EdgeInsets.only(top: 16, bottom: 24 + safeBottom),
          child: GestureDetector(
            onTap: onRetry,
            behavior: HitTestBehavior.opaque,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(
                child: Text(
                  '加载失败，点击重试',
                  style: TextStyle(fontSize: 12, height: 1.2, color: color),
                ),
              ),
            ),
          ),
        );
      case _StreamFooterState.loading:
        return Padding(
          padding: EdgeInsets.only(top: 16, bottom: 24 + safeBottom),
          child: Center(
            child: Text(
              '加载中...',
              style: TextStyle(fontSize: 12, height: 1.2, color: color),
            ),
          ),
        );
    }
  }
}

enum _StreamFooterState { loading, retry, done }
