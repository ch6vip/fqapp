// Upstream source: Wenku8_Flutter rev ebcd7f1
//   lib/backup_page.dart (ArchiveFeaturePage shell, intro copy block,
//     ContentPanel action stack, LoadedContentSequence preview panel,
//     GlassTextButton confirm, featurePadding)
// Mechanical substitutions:
// - fqapp's `LibraryBackupService` / `LibraryBackup` model / snackbar feedback
//   stay unchanged; only presentation moves to the archive vocabulary.
// - Upstream clipboard export and preference toggles are not present in
//   fqapp's backup contract, so they are not rendered.
// - The 番茄 import entry keeps its own route (`FanqieHistoryImportPage`),
//   presented as an upstream `FeatureEntry`.
// - Busy progress uses a linear indicator because fqapp's export/restore
//   reports no per-item totals.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/library_backup.dart';
import '../services/library_backup_service.dart';
import '../services/shelf_group_store.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'ai_reading/settings/ai_settings_widgets.dart';
import 'fanqie_history_import_page.dart';

class LibraryBackupPage extends StatefulWidget {
  const LibraryBackupPage({super.key});

  @override
  State<LibraryBackupPage> createState() => _LibraryBackupPageState();
}

class _LibraryBackupPageState extends State<LibraryBackupPage> {
  final _service = LibraryBackupService();
  LibraryBackup? _preview;
  String? _busy;
  String? _message;
  bool _error = false;
  final _previewKey = GlobalKey();
  final _messageKey = GlobalKey();

  Future<void> _run(
    String label,
    Future<void> Function() action, {
    bool restoring = false,
  }) async {
    if (_busy != null) return;
    setState(() {
      _busy = label;
      _message = null;
      _error = false;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _message = restoring
            ? '恢复未完成，部分记录可能已写入。可重试同一文件，已存在的数据会保留。'
            : switch (error) {
                FormatException() => error.message,
                PlatformException() => error.message ?? '文件操作失败，请重试',
                MissingPluginException() => '当前运行环境不支持系统文件选择器',
                _ => '无法完成操作，请确认本机数据已加载、存储空间充足后重试',
              };
      });
    } finally {
      if (mounted) {
        setState(() => _busy = null);
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

  Future<void> _export() async {
    var hasAiAssets = false;
    try {
      hasAiAssets = (await _service.aiBookIds()).isNotEmpty;
    } catch (_) {
      // AI storage may be locked; the shelf backup remains usable.
    }
    if (!mounted) return;
    final confirmed = !hasAiAssets || (await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('备份包含哪些 AI 数据？'),
        content: const Text(
          '会包含四类校对反馈及其修订历史、认可改法与原文保护、提示词与候选、'
          '试验摘要、用量聚合，以及反馈引用到的正文片段。\n\n'
          '不会包含 API Key、原始请求行、运行明细和试验原始输出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续导出'),
          ),
        ],
      ),
    )) == true;
    if (!confirmed || !mounted) return;
    await _run('正在导出，请在系统窗口选择保存位置…', () async {
      final backup = await _service.capture();
      if (!mounted) return;
      final groupsReady = ShelfGroupStore.instance.isReady;
      final saved = await _service.export(backup);
      if (!mounted) return;
      setState(() {
        _message = saved
            ? '备份文件已保存：${_counts(backup)}。\n'
                  'AI 反馈、保护、提示词和用量已一并导出，API Key 不在文件中。\n'
                  '将这个文件传到新手机，在本页选择导入即可。'
                  '${_service.lastAiExportNote == null ? '' : '\n${_service.lastAiExportNote}'}'
                  '${backup.excludedLocalRecords > 0 ? '\n已排除 ${backup.excludedLocalRecords} 条本地书籍相关记录。' : ''}'
                  '${groupsReady ? '' : '\n本次备份不含书架分组。'}'
            : '已取消导出';
      });
    });
  }

  Future<void> _exportBook() async {
    final ids = await _service.aiBookIds();
    if (!mounted) return;
    if (ids.isEmpty) {
      aiShowSnack(context, '本机还没有可导出的 AI 资产');
      return;
    }
    final sorted = ids.toList()..sort();
    final selected = await showAiChoiceDialog(
      context,
      title: '按书导出 AI 资产',
      message: '每本书一个备份文件；文件仍包含书架和进度，导入时按顺序恢复即可。',
      options: [for (final id in sorted) (key: id, label: id, selected: false)],
    );
    if (selected == null || !mounted) return;
    await _run('正在按书导出…', () async {
      final backup = await _service.capture(aiBookId: selected);
      if (!mounted) return;
      final saved = await _service.export(backup);
      if (!mounted) return;
      setState(() {
        _message = saved
            ? '已按书导出：$selected。${_service.lastAiExportNote == null ? '' : '\n${_service.lastAiExportNote}'}'
            : '已取消导出';
      });
    });
  }

  Future<void> _pick() => _run('请选择备份文件，读取后会显示预览…', () async {
    setState(() => _preview = null);
    final backup = await _service.pick();
    if (!mounted) return;
    setState(() {
      _preview = backup;
      if (backup == null) _message = '已取消选择';
    });
  });

  Future<void> _restore() async {
    final backup = _preview;
    if (backup == null) return;
    await _run('正在恢复，请稍候…', () async {
      final result = await _service.restore(backup);
      if (!mounted) return;
      setState(() {
        _preview = null;
        final groups = backup.groupsIncluded
            ? '、${result.groups} 个分组（${result.assignments} 条分类归属）'
            : '';
        final ai = _service.lastAiRestore;
        _message =
            '恢复完成：新增 ${result.shelf} 条收藏、${result.history} 条进度、'
            '${result.episodes} 集已看标记$groups。\n'
            '保留本机已有收藏/进度 '
            '${backup.shelf.length + backup.history.length - result.shelf - result.history} 条。'
            '${ai == null ? '' : '\n${ai.summary}'}';
      });
    }, restoring: true);
  }

  static String _counts(LibraryBackup backup) =>
      '${backup.shelf.length} 条收藏、${backup.history.length} 条进度、'
      '${backup.episodeCount} 集已看标记'
      '${backup.groupsIncluded ? '、${backup.groupCount} 个分组（${backup.assignmentCount} 条分类归属）' : ''}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final enabled = _busy == null;
    final exportedAt = preview?.createdAt.toLocal().toString().split('.').first;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: scheme.onSurfaceVariant,
    );
    return PopScope(
      canPop: enabled,
      child: ArchiveFeaturePage(
        title: '备份与导入',
        code: 'SYSTEM / DATA TRANSFER',
        canPop: enabled,
        child: ListView(
          key: const ValueKey('backup-scroll'),
          padding: featurePadding(context),
          children: [
            const AppText(
              '书架随你走',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            AppText(
              '备份本机收藏与进度，或从番茄带回书架。只补充缺失的收藏与进度，'
              '保留本机已有记录。',
              style: muted,
            ),
            const SizedBox(height: 24),
            const ArchiveSection(title: '本机数据', code: 'BACKUP / LOCAL'),
            const SizedBox(height: 14),
            ContentPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GlassTextButton(
                    key: const ValueKey('backup-export'),
                    onPressed: enabled ? _export : null,
                    child: const AppText('导出备份'),
                  ),
                  GlassTextButton(
                    key: const ValueKey('backup-export-ai'),
                    onPressed: enabled ? _exportBook : null,
                    child: const AppText('按书导出 AI 资产'),
                  ),
                  GlassTextButton(
                    key: const ValueKey('backup-import'),
                    onPressed: enabled ? _pick : null,
                    child: AppText(preview == null ? '从备份文件恢复' : '重新选择其他备份文件'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const ArchiveSection(title: '其他来源', code: 'BACKUP / OTHER SOURCES'),
            const SizedBox(height: 14),
            FeatureEntry(
              key: const ValueKey('backup-fanqie'),
              title: '导入番茄书架',
              subtitle: '网页登录、最近采集和旧版历史文件',
              icon: LucideIcons.book_open,
              onTap: enabled
                  ? () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const FanqieHistoryImportPage(),
                      ),
                    )
                  : null,
            ),
            if (preview != null) ...[
              const SizedBox(height: 28),
              ArchiveSection(
                key: _previewKey,
                title: '恢复预览',
                code: 'BACKUP / MERGED PREVIEW',
              ),
              const SizedBox(height: 14),
              ContentPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      '备份于 $exportedAt',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _PreviewCounts(backup: preview),
                    const SizedBox(height: 14),
                    AppText(
                      preview.groupsIncluded
                          ? '只补充缺失的收藏、进度与分组，保留本机已有分组与记录。已看剧集会合并，可重复导入。'
                          : '只补充缺失的收藏与进度，保留本机已有记录。已看剧集会合并，可重复导入。',
                      style: muted.copyWith(fontSize: 12),
                    ),
                    if (preview.excludedLocalRecords > 0) ...[
                      const SizedBox(height: 8),
                      AppText(
                        '此备份不含 ${preview.excludedLocalRecords} 条本地书籍记录。',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    GlassTextButton(
                      key: const ValueKey('backup-restore'),
                      onPressed: enabled ? _restore : null,
                      child: const AppText('确认恢复到本机'),
                    ),
                  ],
                ),
              ),
            ],
            if (_busy case final busy?) ...[
              const SizedBox(height: 24),
              AppText(busy, style: muted.copyWith(fontSize: 13)),
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
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
            ContentPanel(
              child: ExpansionTile(
                title: AppText(
                  '备份包含哪些内容？',
                  style: TextStyle(fontSize: 14, color: scheme.onSurface),
                ),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  AppText(
                    '包含在线小说、听书、漫画、短剧和漫剧的收藏、已保存进度、'
                    '已看剧集与书架分组。\n\n'
                    '本地 TXT / EPUB 原文件、下载缓存、阅读时长、划线和应用设置需另行保留。\n\n'
                    '导出前请退出阅读或暂停播放，让当前进度保存；换手机时传输备份文件，再在这里恢复。',
                    style: muted.copyWith(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览面板里的统计，用等宽数字对齐；备份含分组时追加分组与归属两列。
class _PreviewCounts extends StatelessWidget {
  const _PreviewCounts({required this.backup});

  final LibraryBackup backup;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 14,
    runSpacing: 12,
    children: [
      _count(context, '收藏', backup.shelf.length),
      _count(context, '进度', backup.history.length),
      _count(context, '已看剧集', backup.episodeCount),
      if (backup.groupsIncluded) ...[
        _count(context, '分组', backup.groupCount),
        _count(context, '归属', backup.assignmentCount),
      ],
    ],
  );

  Widget _count(BuildContext context, String label, int value) => SizedBox(
    width: 72,
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
}
