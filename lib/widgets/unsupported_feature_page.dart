import 'package:flutter/material.dart';

/// 当前平台没有对应原生实现的页面占位。
///
/// 用于「功能本身在这个平台没做」的情况，与「出错」区分开：这里不展示重试，
/// 也不假装加载中，明确告诉用户去用别的入口。
class UnsupportedFeaturePage extends StatelessWidget {
  const UnsupportedFeaturePage({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
