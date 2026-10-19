import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/media_item.dart';
import '../../services/audio_download_store.dart';
import '../../services/audio_downloader.dart';

/// 听书页「下载」弹层里的**离线音频**区块。
///
/// 文本缓存与音频缓存是两件事：用户在这一页听到的是真人讲书/智能朗读的
/// 加密音频流，只把章节正文存下来，离线时依然打不开播放（issue #81）。
/// 这个区块把当前音色的音频按章下载到本地，播放器命中后即可离线回放。
class AudioOfflineSection extends StatefulWidget {
  const AudioOfflineSection({
    super.key,
    required this.bookId,
    required this.title,
    required this.cover,
    required this.toneId,
    required this.chapters,
    this.downloader,
    this.store,
  });

  final String bookId;
  final String title;
  final String cover;

  /// 当前音色。同一章在不同音色下是两份资源，因此下载也按音色区分。
  final String toneId;
  final List<Chapter> chapters;

  /// 测试注入用；生产走单例。
  final AudioDownloader? downloader;
  final AudioDownloadStore? store;

  @override
  State<AudioOfflineSection> createState() => _AudioOfflineSectionState();
}

class _AudioOfflineSectionState extends State<AudioOfflineSection> {
  AudioDownloader get _downloader =>
      widget.downloader ?? AudioDownloader.instance;
  AudioDownloadStore get _store =>
      widget.store ?? HiveAudioDownloadStore.instance;

  Set<String> _downloaded = const {};
  int _bytes = 0;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _downloader.addListener(_onChanged);
    _store.changes.addListener(_onStoreChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _downloader.removeListener(_onChanged);
    _store.changes.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    // 下载完成会写 store（那边也会通知），这里只在队列清空时刷一次体积。
    if (!_downloader.value.any(
      (task) =>
          task.status == AudioDownloadStatus.downloading ||
          task.status == AudioDownloadStatus.waiting,
    )) {
      unawaited(_refresh());
    }
  }

  void _onStoreChanged() {
    if (!mounted) return;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final ids = await _store.downloadedIds(
        widget.bookId,
        toneId: widget.toneId,
      );
      final bytes = await _store.totalBytes();
      if (!mounted) return;
      setState(() {
        _downloaded = ids;
        _bytes = bytes;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取离线音频记录');
    }
  }

  List<Chapter> get _pending => [
    for (final chapter in widget.chapters)
      if (!_downloaded.contains(chapter.itemId)) chapter,
  ];

  List<AudioDownloadTask> get _mine => [
    for (final task in _downloader.value)
      if (task.bookId == widget.bookId && task.toneId == widget.toneId) task,
  ];

  Future<void> _startDownload() async {
    final pending = _pending;
    if (pending.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _downloader.enqueue(
        book: CachedAudioBook(
          bookId: widget.bookId,
          title: widget.title,
          cover: widget.cover,
          toneId: widget.toneId,
          chapters: widget.chapters,
        ),
        chapters: pending,
      );
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = '无法下载：${error.message}');
    } on Exception catch (error) {
      if (mounted) setState(() => _error = '无法下载：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeAll() async {
    final count = _downloaded.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除离线音频'),
        content: Text('将删除本书当前音色已下载的 $count 章音频，章节正文缓存不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('audio_offline_remove_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _store.removeBook(widget.bookId, toneId: widget.toneId);
      await _refresh();
    } on Exception catch (error) {
      if (mounted) setState(() => _error = '删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.chapters.length;
    final downloaded = _downloaded.length;
    final tasks = _mine;
    final active = tasks.where(
      (task) =>
          task.status == AudioDownloadStatus.downloading ||
          task.status == AudioDownloadStatus.waiting,
    );
    final running = active.isNotEmpty;
    final failed = tasks.firstWhere(
      (task) => task.status == AudioDownloadStatus.failed,
      orElse: () => const AudioDownloadTask(
        bookId: '',
        itemId: '',
        toneId: '',
        title: '',
        index: 0,
        status: AudioDownloadStatus.completed,
      ),
    );
    final pending = _pending;
    final downloadedLabel = downloaded == 0
        ? '尚未下载音频'
        : '已下载 $downloaded / $total 章 · ${_formatBytes(_bytes)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 32),
        Text('离线音频', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          downloadedLabel,
          key: const Key('audio_offline_summary'),
        ),
        const SizedBox(height: 6),
        Text(
          '下载当前音色的讲书音频后，断网也能继续听。音频以加密形态保存在本地，'
          '正文缓存与音频缓存互不影响。',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (running)
              FilledButton.tonalIcon(
                key: const Key('audio_offline_pause'),
                onPressed: () {
                  for (final task in active) {
                    _downloader.pause(task.itemId, toneId: task.toneId);
                  }
                },
                icon: const Icon(Icons.pause_circle_outline),
                label: const Text('暂停下载'),
              )
            else ...[
              FilledButton(
                key: const Key('audio_offline_start'),
                onPressed: _busy || pending.isEmpty
                    ? null
                    : () => unawaited(_startDownload()),
                child: Text(
                  pending.isEmpty
                      ? '本音色已全部下载'
                      : '下载剩余 ${pending.length} 章音频',
                ),
              ),
              if (tasks.any(
                (task) =>
                    task.status == AudioDownloadStatus.paused ||
                    task.status == AudioDownloadStatus.failed,
              ))
                OutlinedButton(
                  key: const Key('audio_offline_resume'),
                  onPressed: _downloader.resumeAll,
                  child: const Text('继续下载'),
                ),
            ],
            if (downloaded > 0)
              TextButton(
                key: const Key('audio_offline_remove'),
                onPressed: running ? null : () => unawaited(_removeAll()),
                child: const Text('删除离线音频'),
              ),
          ],
        ),
        if (running) ...[
          const SizedBox(height: 12),
          Text('正在下载 ${total - pending.length} / $total 章'),
        ],
        if (failed.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${failed.title}：${failed.error}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
