import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../home/home_feed_states.dart';

/// 榜单页的整页空 / 错态。
///
/// 内容区夹在榜单 tab 与分类 chip 下面，高度有限；[HomeStateView] 的
/// `scrollable` 负责居中 + 垂直滚动，窄屏大字号下按钮仍可达。
class RankStateView extends StatelessWidget {
  const RankStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => HomeStateView(
    icon: icon,
    title: title,
    message: message,
    actionLabel: actionLabel,
    actionIcon: LucideIcons.refresh_cw,
    onAction: onAction,
    scrollable: true,
  );
}
