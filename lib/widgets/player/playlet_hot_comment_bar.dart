/// 短剧播放页的热评信息行（官方 `InfoPanelHotCommentView`，布局 `c3g.xml`）。
///
/// 外观采用用户截图里的无底色行：16dp 图标、14sp 文字、1×14dp 分隔线，
/// 尾部「展开」打开对应评论。轮播沿用已接入的热评列表交互：
/// - 列表**第 0 条常显**（`SeriesHotCommentView.java:600`），
///   条数 >1 时每 **5 秒**换下一条（`CountDownTimer(5000,5000)`，`:98-129`），
///   切换动画 200ms：新内容 alpha 0→1 / 位移 +16dp→0，旧内容 alpha 1→0 /
///   位移 0→-16dp（`:287-296`）
/// - 轮播只在「条目被选中且所在页面可见」时走（`v()`:368-407 的
///   holderSelected × parentPageVisibility）；[active] 为 false 时停表
/// - 「展开」仅当正文在压缩宽度下折行才显示（`l2()`:381-538 的
///   StaticLayout 判定），单行内容不出现
/// - 点击：`dataType==Comment(4)` 用自身 commentId；`==Reply(9)` 用
///   parentCommentId（父）+ commentId（回复）（`:468-559`）
///
/// 热评列表不是接口字段，是 [hotOf] 从评论列表筛出来的，因此本组件只吃列表。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/playlet_comment.dart';

class PlayletHotCommentBar extends StatefulWidget {
  const PlayletHotCommentBar({
    super.key,
    required this.comments,
    this.onTap,
    this.active = true,
  });

  /// 官方按「热评」筛选后的列表；为空时整行不出现。
  final List<PlayletComment> comments;

  /// 点击回调：参数是当前展示的那条（官方据此组 hot_comment_id/hot_reply_id）。
  final ValueChanged<PlayletComment>? onTap;

  /// 宿主页可见且未被弹层遮挡；false 时轮播暂停（`v()` 的 sel&&vis）。
  final bool active;

  @override
  State<PlayletHotCommentBar> createState() => _PlayletHotCommentBarState();
}

class _PlayletHotCommentBarState extends State<PlayletHotCommentBar>
    with SingleTickerProviderStateMixin {
  static const _interval = Duration(seconds: 5);
  static const _animation = Duration(milliseconds: 200);
  static const _offset = 16.0;

  late final AnimationController _controller;
  Timer? _timer;
  int _index = 0;
  PlayletComment? _previous;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _animation)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _previous = null);
        }
      });
    _restartTimer();
  }

  @override
  void didUpdateWidget(PlayletHotCommentBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comments.isEmpty && widget.comments.isNotEmpty) {
      _index = 0;
      _previous = null;
      _restartTimer();
    } else if (oldWidget.active != widget.active) {
      // 官方 sel&&vis 变 false 即停表；恢复 true 时立即翻页并重启
      // （`SeriesHotCommentView.z()` 的 B 回调）。
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 官方只在条数 >1 且页面可见时起轮播定时器
  /// （`SeriesHotCommentView.java:124-128`、`v():368-407`）。
  void _restartTimer() {
    _timer?.cancel();
    if (!widget.active || widget.comments.length <= 1) return;
    _timer = Timer.periodic(_interval, (_) => _advance());
  }

  void _advance() {
    if (!mounted || widget.comments.length <= 1) return;
    setState(() {
      _previous = _current;
      _index = (_index + 1) % widget.comments.length;
    });
    _controller.forward(from: 0);
  }

  PlayletComment? get _current => widget.comments.isEmpty
      ? null
      : widget.comments[_index % widget.comments.length];

  @override
  Widget build(BuildContext context) {
    final current = _current;
    if (current == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        return Align(
          alignment: Alignment.centerLeft,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.isAnimating || _controller.isCompleted
                  ? _controller.value
                  : 1.0;
              final previous = _previous;
              return ClipRect(
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (previous != null)
                      IgnorePointer(
                        child: Opacity(
                          opacity: 1 - t,
                          child: Transform.translate(
                            offset: Offset(0, -_offset * t),
                            child: _row(previous, maxWidth),
                          ),
                        ),
                      ),
                    Opacity(
                      opacity: previous == null ? 1 : t,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          previous == null ? 0 : _offset * (1 - t),
                        ),
                        child: _row(current, maxWidth),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _row(PlayletComment comment, double maxWidth) {
    final showExpand = _needsExpand(comment, maxWidth);
    return GestureDetector(
      key: ValueKey('playlet-hot-comment-${comment.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap?.call(comment),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/images/drama/hot_comment.webp',
            width: 16,
            height: 16,
          ),
          const SizedBox(width: 2),
          const Text('热评', style: TextStyle(fontSize: 14, color: Colors.white)),
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: const Color(0x4DFFFFFF),
          ),
          Flexible(
            child: Text(
              _label(comment),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: Color(0xB3FFFFFF)),
            ),
          ),
          // 「展开」只在正文折行时出现，且占位参与正文宽度分配
          // （`InfoPanelHotCommentView.l2()` 的 withExpand 压缩）。
          if (showExpand) ...[
            const SizedBox(width: 6),
            const Text('展开', style: TextStyle(fontSize: 14, color: Colors.white)),
          ],
        ],
      ),
    );
  }

  /// 官方 l2()/b2() 的判定：先按「扣掉图标 16 + 间距 2 + 标签实测宽 +
  /// 分隔 13 + 展开实测宽 + 间距 6」的压缩宽度对正文做单行测量，
  /// 折行（StaticLayout lineCount > 1）才显示「展开」。
  bool _needsExpand(PlayletComment comment, double maxWidth) {
    if (!maxWidth.isFinite || maxWidth <= 0) return false;
    final scaler = MediaQuery.textScalerOf(context);
    final style = const TextStyle(fontSize: 14, color: Color(0xB3FFFFFF));
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      return painter.width;
    }

    const fixed = 16.0 + 2.0 + 13.0;
    final reserved = fixed + measure('热评') + 6.0 + measure('展开');
    final painter = TextPainter(
      text: TextSpan(text: _label(comment), style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout(maxWidth: math.max(1.0, maxWidth - reserved));
    return painter.didExceedMaxLines;
  }

  /// 行首已有「热评」，正文只保留演员/主演的特殊前缀，避免重复标签。
  /// 官方 roleType 0=主演、1=演员（`InfoPanelHotCommentView.z2()`）。
  String _label(PlayletComment comment) =>
      comment.playletRoleType == 0 || comment.playletRoleType == 1
      ? '${comment.rolePrefix}${comment.text}'
      : comment.text;
}
