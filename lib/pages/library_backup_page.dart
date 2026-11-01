import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/library_backup.dart';
import '../services/library_backup_service.dart';
import '../widgets/home/home_design.dart';
import '../widgets/data_transfer_widgets.dart';
import '../widgets/settings/settings_widgets.dart';
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

  Future<void> _export() => _run('正在导出，请在系统窗口选择保存位置…', () async {
    final backup = await _service.capture();
    if (!mounted) return;
    final saved = await _service.export(backup);
    if (!mounted) return;
    setState(() {
      _message = saved
          ? '备份文件已保存：${_counts(backup)}。\n'
                '将这个文件传到新手机，在本页选择导入即可。'
                '${backup.excludedLocalRecords > 0 ? '\n已排除 ${backup.excludedLocalRecords} 条本地书籍相关记录。' : ''}'
          : '已取消导出';
    });
  });

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
        _message =
            '恢复完成：新增 ${result.shelf} 条收藏、${result.history} 条进度、'
            '${result.episodes} 集已看标记。\n'
            '保留本机已有收藏/进度 '
            '${backup.shelf.length + backup.history.length - result.shelf - result.history} 条。';
      });
    }, restoring: true);
  }

  static String _counts(LibraryBackup backup) =>
      '${backup.shelf.length} 条收藏、${backup.history.length} 条进度、'
      '${backup.episodeCount} 集已看标记';

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final preview = _preview;
    final enabled = _busy == null;
    final exportedAt = preview?.createdAt.toLocal().toString().split('.').first;
    return PopScope(
      canPop: enabled,
      child: Scaffold(
        backgroundColor: palette.canvas,
        appBar: settingsAppBar(context, title: '备份与导入'),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  const DataTransferHeader(
                    icon: LucideIcons.database,
                    title: '书架随你走',
                    subtitle: '备份本机收藏与进度，或从番茄带回书架。',
                  ),
                  const SettingsSectionHeader(title: '本机数据'),
                  SettingsGroupCard(
                    children: [
                      SettingsRow(
                        icon: LucideIcons.download,
                        iconTile: true,
                        title: '导出备份',
                        subtitle: '保存收藏、阅读进度与已看剧集',
                        enabled: enabled,
                        onTap: enabled ? _export : null,
                      ),
                      SettingsRow(
                        icon: LucideIcons.file_input,
                        iconTile: true,
                        title: '从备份文件恢复',
                        subtitle: preview == null
                            ? '选择 FQApp 备份文件，预览后再合并'
                            : '重新选择其他 FQApp 备份',
                        enabled: enabled,
                        onTap: enabled ? _pick : null,
                      ),
                    ],
                  ),
                  const SettingsSectionHeader(title: '其他来源'),
                  SettingsGroupCard(
                    children: [
                      SettingsRow(
                        icon: LucideIcons.book_open,
                        iconTile: true,
                        title: '导入番茄书架',
                        subtitle: '网页登录、最近采集和旧版历史文件',
                        enabled: enabled,
                        onTap: enabled
                            ? () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      const FanqieHistoryImportPage(),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                  if (preview != null) ...[
                    SettingsSectionHeader(title: '恢复预览', key: _previewKey),
                    SettingsGroupCard(
                      showDividers: false,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '备份于 $exportedAt',
                                style: TextStyle(
                                  color: palette.muted,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 14),
                              DataTransferStats(
                                values: {
                                  '收藏': preview.shelf.length,
                                  '进度': preview.history.length,
                                  '已看剧集': preview.episodeCount,
                                },
                              ),
                              const SizedBox(height: 14),
                              Text(
                                '只补充缺失的收藏与进度，保留本机已有记录。已看剧集会合并，可重复导入。',
                                style: TextStyle(
                                  color: palette.ink,
                                  fontSize: 13,
                                  height: 1.6,
                                ),
                              ),
                              if (preview.excludedLocalRecords > 0) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '此备份不含 ${preview.excludedLocalRecords} 条本地书籍记录。',
                                  style: TextStyle(
                                    color: palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_message case final message?) ...[
                    const SizedBox(height: 16),
                    DataTransferNotice(
                      key: _messageKey,
                      message: message,
                      error: _error,
                    ),
                  ],
                  const SizedBox(height: 24),
                  SettingsGroupCard(
                    showDividers: false,
                    children: [
                      ExpansionTile(
                        title: Text(
                          '备份包含哪些内容？',
                          style: TextStyle(color: palette.ink, fontSize: 14),
                        ),
                        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          16,
                        ),
                        children: [
                          Text(
                            '包含在线小说、听书、漫画、短剧和漫剧的收藏、已保存进度，以及已看剧集。\n\n'
                            '本地 TXT / EPUB 原文件、下载缓存、阅读时长、划线和应用设置需另行保留。\n\n'
                            '导出前请退出阅读或暂停播放，让当前进度保存；换手机时传输备份文件，再在这里恢复。',
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 13,
                              height: 1.7,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: _busy != null || preview != null
            ? SafeArea(
                top: false,
                child: Container(
                  color: palette.canvas,
                  padding: const EdgeInsets.all(16),
                  child: _busy != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const LinearProgressIndicator(),
                            const SizedBox(height: 10),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                _busy!,
                                style: TextStyle(
                                  color: palette.ink,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        )
                      : DataTransferAction(
                          label: '确认恢复到本机',
                          onPressed: _restore,
                        ),
                ),
              )
            : null,
      ),
    );
  }
}
