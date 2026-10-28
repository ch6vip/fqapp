import 'dart:async';

import 'package:flutter/material.dart';

import '../../pages/system_tts_settings_page.dart';
import '../../services/audio_floating_routes.dart';
import '../../services/system_tts.dart';

class SystemTtsPlaybackPage extends StatelessWidget {
  const SystemTtsPlaybackPage({
    super.key,
    required this.session,
    required this.onClose,
  });
  final SystemTtsPlayback session;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // The TTS counterpart of AudioPlayActivity hides the capsule.
    AudioFloatingRouteScope.configure(context, hidden: true);
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('系统朗读'),
      actions: [
        IconButton(
          tooltip: '朗读设置',
          icon: const Icon(Icons.settings_voice),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
          ),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            session.book.title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(session.chapter.title),
          const SizedBox(height: 24),
          LinearProgressIndicator(
            value: session.loading ? null : session.progress,
          ),
          const SizedBox(height: 12),
          Text(
            session.closed
                ? '朗读已关闭'
                : session.error ??
                      (session.loading
                          ? '正在准备朗读…'
                          : session.completed
                          ? '全书朗读完毕'
                          : '本章 ${(session.progress * 100).round()}%'),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 24,
            children: [
              IconButton(
                tooltip: '上一章',
                icon: const Icon(Icons.skip_previous),
                onPressed: session.closed || session.index == 0
                    ? null
                    : () => unawaited(session.openChapter(session.index - 1)),
              ),
              FilledButton.icon(
                onPressed: session.closed
                    ? null
                    : () => unawaited(session.toggle()),
                icon: Icon(session.wantPlay ? Icons.pause : Icons.play_arrow),
                label: Text(
                  session.wantPlay
                      ? '暂停'
                      : session.error != null
                      ? '重试'
                      : '继续',
                ),
              ),
              IconButton(
                tooltip: '下一章',
                icon: const Icon(Icons.skip_next),
                onPressed:
                    session.closed ||
                        session.index + 1 >= session.book.chapters.length
                    ? null
                    : () => unawaited(session.openChapter(session.index + 1)),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            '返回阅读页或浏览其他页面可继续听。自动朗读下一章，受“后台播放”设置控制。续读位置保留在当前会话内；关闭朗读或重启应用后，从阅读页重新开始。',
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () {
              onClose();
              Navigator.of(context).pop();
            },
            child: const Text('关闭朗读'),
          ),
        ],
      ),
    ),
  );
}
