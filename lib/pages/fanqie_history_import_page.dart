// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/legacy_import_page.dart (ArchiveFeaturePage shell, intro copy,
//     FeatureEntry choose action, LoadedContentSequence preview panel,
//     GlassTextButton merge)
//   lib/offline_widgets.dart (ContentPanel list rhythm)
// Mechanical substitutions:
// - fqapp restores local history files and previously saved capture data;
//   account login and online capture are not part of this page.
// - The bottom action bar becomes in-panel upstream-style buttons; busy state
//   is an inline progress row with the same cancel action.
// - `AppText`/`ContentPanel`/`ArchiveSection`/`FeatureEntry`/`FeatureError`
//   come from the vendored shared layer. `appText` is unnecessary (one locale).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/fanqie_library_capture.dart';
import '../services/backend_transport.dart';
import '../services/fanqie_history_import_service.dart';
import '../services/fanqie_library_capture_service.dart';
import '../services/fanqie_library_import_service.dart';
import '../widgets/wenku/wenku_ui.dart';

class FanqieHistoryImportPage extends StatefulWidget {
  const FanqieHistoryImportPage({super.key});

  @override
  State<FanqieHistoryImportPage> createState() =>
      _FanqieHistoryImportPageState();
}

class _FanqieHistoryImportPageState extends State<FanqieHistoryImportPage> {
  final _service = FanqieHistoryImportService();
  final _collector = FanqieLibraryCaptureService();
  FanqieLibraryCapture? _capture;
  final _libraryImporter = FanqieLibraryImportService();
  FanqieImportPreview? _libraryPreview;
  String? _captureProgress;
  BackendRequest? _request;
  bool _error = false;
  bool _loadingLatest = true;
  String _previewSource = '已保存数据';
  bool _busy = false;
  String? _message;
  final _previewKey = GlobalKey();
  final _messageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    unawaited(_loadLatest());
  }

  @override
  void dispose() {
    _cancelRead();
    super.dispose();
  }

  void _cancelRead() {
    _request?.cancel();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = switch (error) {
          FormatException() => error.message,
          BackendRequestAborted() => '读取已取消，未导入本机',
          MissingPluginException() => '当前环境不支持此操作，请使用 Android 应用',
          // Never display raw platform/network exceptions containing account data.
          PlatformException() => '文件操作未完成，请重试',
          _ => '操作未完成，请检查网络后重试。若正在合并，部分记录可能已写入，可重复导入。',
        };
      });
    } finally {
      _request = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _captureProgress = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final target =
              (_message != null ? _messageKey : _previewKey).currentContext;
          if (target != null) {
            unawaited(
              Scrollable.ensureVisible(
                target,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                alignment: .1,
              ),
            );
          }
        });
      }
    }
  }

  Future<void> _pick() => _run(() async {
    setState(() => _libraryPreview = null);
    final preview = await _service.pickFile();
    if (!mounted) return;
    setState(() {
      if (preview == null) {
        _message = '已取消选择';
      } else {
        _previewSource = '历史文件';
        _libraryPreview = FanqieImportPreview(
          [
            for (final record in preview.validated.history)
              {
                ...record,
                'author': record['author'] ?? '',
                'fanqieImported': true,
              },
          ],
          0,
          0,
          preview.sourceCount - preview.validated.history.length,
        );
      }
    });
  });

  Future<void> _resumeMetadata() => _run(() async {
    final seed = _capture;
    if (seed == null) return;
    setState(() => _libraryPreview = null);
    final request = BackendRequest();
    _request = request;
    final capture = await _collector.completeMetadata(seed, request, (message) {
      if (mounted) setState(() => _captureProgress = message);
    });
    if (mounted) setState(() => _capture = capture);
    final saved = await _collector.save(capture);
    if (mounted) {
      setState(
        () => _message = saved ? '补取结果已保存，可导出完整分卷包；未修改本机书架' : '保存未完成，请先导出当前结果',
      );
    }
  });

  Future<void> _prepareLibrary() => _run(() async {
    final capture = _capture;
    if (capture == null) return;
    setState(() => _libraryPreview = null);
    final request = BackendRequest();
    _request = request;
    final preview = await _libraryImporter.prepare(capture, request, (message) {
      if (mounted) setState(() => _captureProgress = message);
    });
    if (mounted) {
      setState(() {
        _libraryPreview = preview;
        _previewSource = '番茄书架';
      });
    }
  });

  Future<void> _mergeLibrary() => _run(() async {
    final preview = _libraryPreview;
    if (preview == null) return;
    final result = await _libraryImporter.merge(preview);
    if (mounted) {
      setState(() {
        _libraryPreview = null;
        _message =
            '已合并书架 ${result.shelf} 本、历史 ${result.history} 本；'
            '保留较新的本机阅读位置。重复导入不会产生重复书籍。';
      });
    }
  });

  Future<void> _loadLatest() async {
    try {
      final capture = await _collector.latest();
      if (mounted) setState(() => _capture = capture);
    } on Exception {
      // File import stays available if no saved capture can be read.
    } finally {
      if (mounted) setState(() => _loadingLatest = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _libraryPreview;
    final capture = _capture;
    final enabled = !_busy && !_loadingLatest;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: scheme.onSurfaceVariant,
    );
    return PopScope(
      canPop: !_busy,
      child: ArchiveFeaturePage(
        title: '导入番茄书架',
        code: 'MIGRATION / FANQIE',
        canPop: !_busy,
        child: ListView(
          key: const ValueKey('fanqie-import-scroll'),
          padding: featurePadding(context),
          children: [
            const AppText(
              '书架和进度，一起带回来',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            AppText('从本地文件恢复小说书架与历史。有章节记录的书，可以接着读。', style: muted),
            const SizedBox(height: 24),
            const ArchiveSection(title: '选择导入来源', code: 'MIGRATION / SOURCE'),
            const SizedBox(height: 14),
            ContentPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GlassTextButton(
                    key: const ValueKey('fanqie-pick'),
                    onPressed: enabled ? _pick : null,
                    child: const AppText('从历史文件导入'),
                  ),
                ],
              ),
            ),
            if (_loadingLatest)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_busy) ...[
              const SizedBox(height: 20),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: AppText(
                        _captureProgress ?? '正在处理，请稍候…',
                        style: muted.copyWith(fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                    if (_request != null)
                      GlassTextButton(
                        onPressed: _cancelRead,
                        child: const AppText('取消读取'),
                      ),
                  ],
                ),
              ),
            ],
            if (capture != null) ...[
              const SizedBox(height: 28),
              const ArchiveSection(
                title: '此前保存的数据',
                code: 'MIGRATION / CAPTURED',
              ),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      '${capture.received} 个响应已保存在本机'
                      '${capture.stopReason.isNotEmpty ? ' · 部分采集' : ''}',
                      style: muted.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 14),
                    GlassTextButton(
                      key: const ValueKey('fanqie-use-capture'),
                      onPressed: enabled ? _prepareLibrary : null,
                      child: const AppText('使用已保存的书架数据'),
                    ),
                    ExpansionTile(
                      title: AppText(
                        '采集详情与文件',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      children: [
                        if (capture.stopReason.isNotEmpty)
                          FeatureError(capture.stopReason),
                        AppText(
                          '已保存 ${capture.parts.length} 个分卷，失败 ${capture.failed} 个响应。响应数量不是书籍数量。',
                          style: muted.copyWith(fontSize: 12),
                        ),
                        for (final group in _captureSummary(capture).entries)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: AppText(
                                    group.key,
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                Flexible(
                                  child: AppText(
                                    group.value,
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            GlassTextButton(
                              compact: true,
                              onPressed: enabled ? _resumeMetadata : null,
                              child: const AppText('补齐书籍资料'),
                            ),
                            GlassTextButton(
                              compact: true,
                              onPressed: enabled
                                  ? () => _run(() async {
                                      final saved = await _collector.export(
                                        capture,
                                      );
                                      if (mounted) {
                                        setState(
                                          () => _message = saved
                                              ? '原始数据文件已导出'
                                              : '已取消导出',
                                        );
                                      }
                                    })
                                  : null,
                              child: const AppText('导出原始数据'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (parsed != null) ...[
              const SizedBox(height: 28),
              ArchiveSection(
                key: _previewKey,
                title: '导入预览 · $_previewSource',
                code: 'MIGRATION / PREVIEW',
                subtitle: parsed.records.isEmpty
                    ? ''
                    : '共 ${parsed.records.length} 本',
              ),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _previewCount(context, '小说', parsed.records.length),
                        const SizedBox(width: 14),
                        _previewCount(context, '章节已定位', parsed.matched),
                        const SizedBox(width: 14),
                        _previewCount(context, '待重试', parsed.unresolved),
                      ],
                    ),
                    const SizedBox(height: 14),
                    AppText(
                      '同时加入书架和历史，保留较新的本机阅读位置。',
                      style: muted.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    AppText(
                      '未取得章节的作品从头开始；已定位的作品从对应章节开头续读。',
                      style: muted.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    for (final record in parsed.records.take(6))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            _cover(record, scheme),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AppText(
                                    (record['title'] as String).isEmpty
                                        ? '未注明书名'
                                        : record['title'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  AppText(
                                    record['ep'] as String? ??
                                        (record['chapterId'] == null
                                            ? '未取得阅读章节'
                                            : '打开时重新匹配章节'),
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (parsed.records.length > 6)
                      AppText(
                        '仅展示前 6 本，导入包含全部 ${parsed.records.length} 本小说',
                        style: muted.copyWith(fontSize: 12),
                      ),
                    const SizedBox(height: 8),
                    GlassTextButton(
                      key: const ValueKey('fanqie-merge'),
                      onPressed: enabled && parsed.records.isNotEmpty
                          ? _mergeLibrary
                          : null,
                      child: AppText('导入 ${parsed.records.length} 本到书架和历史'),
                    ),
                  ],
                ),
              ),
            ],
            if (_message case final message?) ...[
              const SizedBox(height: 20),
              KeyedSubtree(
                key: _messageKey,
                child: _error
                    ? FeatureError(message)
                    : ContentPanel(
                        child: AppText(
                          message,
                          style: muted.copyWith(fontSize: 13),
                        ),
                      ),
              ),
            ],
            const SizedBox(height: 24),
            AppText(
              '仅处理本地文件和此前保存的数据，不提供账号登录或账号数据读取。'
              '补齐资料与章节匹配只请求公开书籍信息；确认导入后才合并本机书架和历史。',
              style: muted.copyWith(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewCount(BuildContext context, String label, int value) =>
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            AppText(
              '$value',
              style: const TextStyle(
                fontSize: 24,
                height: 1.1,
                fontWeight: FontWeight.w500,
                letterSpacing: -.6,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );

  Widget _cover(Map<String, dynamic> record, ColorScheme scheme) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: SizedBox(
      width: 34,
      height: 46,
      child: (record['cover'] as String? ?? '').isEmpty
          ? ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Icon(
                LucideIcons.book_open,
                color: scheme.onSurfaceVariant,
                size: 18,
              ),
            )
          : Image.network(
              record['cover'] as String,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  LucideIcons.book_open,
                  color: scheme.onSurfaceVariant,
                  size: 18,
                ),
              ),
            ),
    ),
  );

  Map<String, String> _captureSummary(FanqieLibraryCapture capture) {
    const labels = {
      'shelf_list': '书架列表',
      'shelf_info': '书架完整信息',
      'history': '阅读历史',
      'progress_list': '进度列表',
      'progress_batch': '按作品查询进度',
      'folder_list': '文件夹列表',
      'folder_detail': '文件夹内容',
      'topping': '置顶信息',
      'tabs': '书架标签',
      'book_detail': '书籍详情',
    };
    return {
      for (final entry in labels.entries)
        entry.value: [
          for (final status in ['received', 'failed', 'incomplete'])
            '${{'received': '收到', 'failed': '失败', 'incomplete': '分页未完成'}[status]} '
                '${capture.sources.where((s) => s['resource'] == entry.key && s['status'] == status).length}',
        ].join(' / '),
    };
  }
}
