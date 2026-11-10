// Two presentations, one backup service.
//
// Archive keeps the Wenku8 rev ebcd7f1 `ArchiveFeaturePage` shell from #291
// (`ArchiveSection` + `ContentPanel` + `GlassTextButton`); classic restores the
// pre-#291 `settingsAppBar` layout from fqapp-backup@f329399
// (`DataTransferHeader` + `SettingsGroupCard` + fixed bottom action).
//
// fqapp's `LibraryBackupService` / `LibraryBackup` model, the snackbar/scroll
// feedback, the AI-compatible export options (whole backup and per-book AI
// assets), the group counts and the 番茄 import route are shared by both.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/library_backup.dart';
import '../services/app_theme_style.dart';
import '../services/library_backup_service.dart';
import '../services/shelf_group_store.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/data_transfer_widgets.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_scroll_anchor.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'ai_reading/settings/ai_settings_widgets.dart';
import 'fanqie_history_import_page.dart';
import 'webdav_sync_page.dart';

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

  /// Expanded state of the "备份包含哪些内容？" block. Owned by the page, not the
  /// card: the card's shell changes with the presentation and the list item is
  /// disposed once it scrolls out of view.
  bool _helpExpanded = false;
  final _previewKey = GlobalKey();
  final _messageKey = GlobalKey();

  /// One list for both presentations, so the scroll position survives the
  /// shell switch and the visible section can be re-anchored.
  final _scroll = ScrollController();
  late final _anchor = SettingsScrollAnchor(_scroll);

  @override
  void dispose() {
    _anchor.dispose();
    _scroll.dispose();
    super.dispose();
  }

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
    final confirmed =
        !hasAiAssets ||
        (await showDialog<bool>(
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
            )) ==
            true;
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
    final style = AppUiScope.of(context);
    final classic = style == AppThemeStyle.classic;
    _anchor.track(style);
    final scheme = Theme.of(context).colorScheme;
    final palette = HomePalette.of(context);
    final preview = _preview;
    final enabled = _busy == null;
    final exportedAt = preview?.createdAt.toLocal().toString().split('.').first;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: classic ? palette.ink : scheme.onSurfaceVariant,
    );
    final content = <Widget>[
      KeyedSubtree(
        key: _anchor.keyFor('heading'),
        child: const SettingsHeading(
          title: '书架随你走',
          subtitle:
              '备份本机收藏与进度，或从番茄带回书架。只补充缺失的收藏与进度，'
              '保留本机已有记录。',
        ),
      ),
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _anchor.keyFor('local'),
        child: const SettingsSection(
          key: ValueKey('backup-local-section'),
          title: '本机数据',
          code: 'BACKUP / LOCAL',
        ),
      ),
      const SizedBox(height: 14),
      SettingsCard(
        archiveDividers: false,
        children: [
          SettingsActionRow(
            key: const ValueKey('backup-export'),
            icon: CupertinoIcons.tray_arrow_down,
            classicIcon: LucideIcons.download,
            title: '导出备份',
            subtitle: '保存收藏、阅读进度与已看剧集',
            enabled: enabled,
            onPressed: _export,
          ),
          SettingsActionRow(
            key: const ValueKey('backup-export-ai'),
            icon: CupertinoIcons.doc_on_doc,
            classicIcon: LucideIcons.files,
            title: '按书导出 AI 资产',
            subtitle: '单个备份仍超 16 MB 时使用；每本书一个文件',
            enabled: enabled,
            onPressed: _exportBook,
          ),
          SettingsActionRow(
            key: const ValueKey('backup-import'),
            icon: CupertinoIcons.tray_arrow_up,
            classicIcon: LucideIcons.file_input,
            title: '从备份文件恢复',
            subtitle: preview == null
                ? '选择 FQApp 备份文件，预览后再合并'
                : '重新选择其他 FQApp 备份文件',
            enabled: enabled,
            onPressed: _pick,
          ),
        ],
      ),
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _anchor.keyFor('webdav'),
        child: const SettingsSection(title: '云端同步', code: 'SYNC / WEBDAV'),
      ),
      const SizedBox(height: 14),
      SettingsEntryCard(
        key: const ValueKey('backup-webdav'),
        icon: LucideIcons.cloud,
        title: 'WebDAV 同步',
        subtitle: '自动同步书架和阅读进度',
        enabled: enabled,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const WebDavSyncPage()),
        ),
      ),
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _anchor.keyFor('sources'),
        child: const SettingsSection(
          title: '其他来源',
          code: 'BACKUP / OTHER SOURCES',
        ),
      ),
      const SizedBox(height: 14),
      SettingsEntryCard(
        key: const ValueKey('backup-fanqie'),
        icon: LucideIcons.book_open,
        title: '导入番茄书架',
        subtitle: '网页登录、最近采集和旧版历史文件',
        enabled: enabled,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const FanqieHistoryImportPage(),
          ),
        ),
      ),
      if (preview != null) ...[
        const SizedBox(height: 28),
        KeyedSubtree(
          key: _anchor.keyFor('preview'),
          child: SettingsSection(
            key: _previewKey,
            title: '恢复预览',
            code: 'BACKUP / MERGED PREVIEW',
          ),
        ),
        const SizedBox(height: 14),
        SettingsCard(
          classicDividers: false,
          children: [
            SettingsCardRow(
              classicPadding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '备份于 $exportedAt',
                    style: TextStyle(
                      fontSize: 12,
                      color: classic ? palette.muted : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SettingsStats(
                    values: {
                      '收藏': preview.shelf.length,
                      '进度': preview.history.length,
                      '已看剧集': preview.episodeCount,
                      if (preview.groupsIncluded) ...{
                        '分组': preview.groupCount,
                        '归属': preview.assignmentCount,
                      },
                    },
                  ),
                  const SizedBox(height: 14),
                  Text(
                    preview.groupsIncluded
                        ? '只补充缺失的收藏、进度与分组，保留本机已有分组与记录。'
                              '已看剧集会合并，可重复导入。'
                        : '只补充缺失的收藏与进度，保留本机已有记录。'
                              '已看剧集会合并，可重复导入。',
                    style: muted.copyWith(fontSize: 12),
                  ),
                  if (preview.excludedLocalRecords > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '此备份不含 ${preview.excludedLocalRecords} 条本地书籍记录。',
                      style: TextStyle(
                        fontSize: 12,
                        color: classic
                            ? palette.muted
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  // Classic keeps the restore action in the fixed bottom bar,
                  // exactly like the pre-#291 page.
                  if (!classic) ...[
                    const SizedBox(height: 16),
                    SettingsAction(
                      key: const ValueKey('backup-restore'),
                      label: '确认恢复到本机',
                      onPressed: enabled ? _restore : null,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
      if (!classic && _busy != null) ...[
        const SizedBox(height: 24),
        AppText(_busy!, style: muted.copyWith(fontSize: 13)),
        const SizedBox(height: 10),
        const LinearProgressIndicator(minHeight: 2),
      ],
      if (_message case final message?) ...[
        const SizedBox(height: 20),
        KeyedSubtree(
          key: _messageKey,
          child: SettingsMessage(message: message, error: _error),
        ),
      ],
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _anchor.keyFor('help'),
        child: SettingsCard(
          classicDividers: false,
          children: [
            SettingsDisclosure(
              key: const ValueKey('backup-help'),
              title: '备份包含哪些内容？',
              expanded: _helpExpanded,
              onExpandedChanged: (value) =>
                  setState(() => _helpExpanded = value),
              children: [
                Text(
                  '包含在线小说、听书、漫画、短剧和漫剧的收藏、已保存进度、'
                  '已看剧集与书架分组。\n\n'
                  '本地 TXT / EPUB 原文件、下载缓存、阅读时长、划线和应用设置需另行保留。\n\n'
                  '导出前请退出阅读或暂停播放，让当前进度保存；换手机时传输备份文件，再在这里恢复。',
                  style: muted.copyWith(fontSize: 13),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
    return PopScope(
      canPop: enabled,
      child: SettingsArchivePage(
        title: '备份与导入',
        code: 'SYSTEM / DATA TRANSFER',
        classicBottomBar: classic && (_busy != null || _preview != null)
            ? _classicBottomBar(context)
            : null,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: classic ? 640 : 760),
            child: ListView(
              key: const ValueKey('backup-scroll'),
              controller: _scroll,
              padding: featurePadding(context),
              children: content,
            ),
          ),
        ),
      ),
    );
  }

  /// Classic fixed action bar: busy progress or the restore confirmation.
  Widget _classicBottomBar(BuildContext context) {
    final palette = HomePalette.of(context);
    return SafeArea(
      top: false,
      child: Container(
        color: palette.canvas,
        padding: const EdgeInsets.all(16),
        child: _busy == null
            ? DataTransferAction(
                label: '确认恢复到本机',
                onPressed: _preview == null ? null : _restore,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _busy!,
                      style: TextStyle(color: palette.ink, fontSize: 13),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
