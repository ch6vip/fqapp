/// 短剧播放页的「热评」胶囊（官方 `SeriesHotCommentView`，布局 `chk.xml`）。
///
/// 官方规格（`res/layout/chk.xml` + `SeriesHotCommentView.java`）：
/// - 胶囊底 `@color/au`=**#33ffffff**、圆角 4dp、左右内边距 4dp、上下 4dp
/// - 内容：16dp 图标 + 「热评」12sp 纯白（`@string/dze`，maxLength 12）
///   + 1×10dp 分隔线 `@color/awx`=#4dffffff + 正文 12sp 纯白（单行省略）
///   + 尾部 10dp 箭头
/// - 轮播：列表**第 0 条常显**（`SeriesHotCommentView.java:600`），
///   条数 >1 时每 **5 秒**换下一条（`CountDownTimer(5000,5000)`，`:98-129`），
///   切换动画 200ms：新内容 alpha 0→1 / 位移 +16dp→0，旧内容 alpha 1→0 /
///   位移 0→-16dp（`:287-296`）
/// - 点击：`dataType==Comment(4)` 用自身 commentId；`==Reply(9)` 用
///   parentCommentId（父）+ commentId（回复）（`:468-559`）
///
/// 热评列表不是接口字段，是 [hotOf] 从评论列表筛出来的，因此本组件只吃列表。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/playlet_comment.dart';

class PlayletHotCommentBar extends StatefulWidget {
  const PlayletHotCommentBar({super.key, required this.comments, this.onTap});

  /// 官方按「热评」筛选后的列表；为空时整个胶囊不出现。
  final List<PlayletComment> comments;

  /// 点击回调：参数是当前展示的那条（官方据此组 hot_comment_id/hot_reply_id）。
  final ValueChanged<PlayletComment>? onTap;

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
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 官方只在条数 >1 时起轮播定时器（`SeriesHotCommentView.java:124-128`）。
  void _restartTimer() {
    _timer?.cancel();
    if (widget.comments.length <= 1) return;
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

  PlayletComment? get _current =>
      widget.comments.isEmpty ? null : widget.comments[_index % widget.comments.length];

  @override
  Widget build(BuildContext context) {
    final current = _current;
    if (current == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.isAnimating || _controller.isCompleted
              ? _controller.value
              : 1.0;
          final previous = _previous;
          return DecoratedBox(
            decoration: BoxDecoration(
              // 官方 `@color/au`=#33ffffff，圆角 4dp。
              color: const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: SizedBox(
                height: 20,
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (previous != null)
                      Opacity(
                        opacity: 1 - t,
                        child: Transform.translate(
                          offset: Offset(0, -_offset * t),
                          child: _row(previous),
                        ),
                      ),
                    Opacity(
                      opacity: previous == null ? 1 : t,
                      child: Transform.translate(
                        offset: Offset(0, previous == null ? 0 : _offset * (1 - t)),
                        child: _row(current),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(PlayletComment comment) => GestureDetector(
    key: ValueKey('playlet-hot-comment-${comment.id}'),
    behavior: HitTestBehavior.opaque,
    onTap: () => widget.onTap?.call(comment),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.local_fire_department_rounded,
          size: 16,
          color: Colors.white,
        ),
        const SizedBox(width: 2),
        const Text(
          '热评',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        Container(
          width: 1,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: const Color(0x4DFFFFFF),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            _label(comment),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.white),
          ),
        ),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right_rounded, size: 14, color: Colors.white),
      ],
    ),
  );

  /// 官方前缀由 `playlet_role_type` 决定（0x7f061960/61/62）。
  String _label(PlayletComment comment) =>
      '${comment.rolePrefix}${comment.text}';
}
