// Two presentations, one import pipeline.
//
// Archive keeps the Wenku8 rev ebcd7f1 `ArchiveFeaturePage` shell from #291
// (`ArchiveSection` + `ContentPanel` + `GlassTextButton`, inline busy panel);
// classic restores the pre-#291 layout from fqapp-backup@f329399
// (`DataTransferHeader` + `SettingsGroupCard` rows + fixed bottom action bar).
//
// fqapp's 番茄 login / capture / preview / merge services, the private capture
// cache, the raw-data export and the error mapping are shared by both. No
// legacy-save directory picker is rendered: fqapp imports 番茄 data instead.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/fanqie_library_capture.dart';
import '../services/backend_transport.dart';
import '../services/fanqie_history_import_service.dart';
import '../services/fanqie_library_capture_service.dart';
import '../services/app_theme_style.dart';
import '../services/fanqie_library_import_service.dart';
import '../services/linux_platform.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/data_transfer_widgets.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_scroll_anchor.dart';
import '../widgets/wenku/wenku_ui.dart';

class FanqieHistoryImportPage extends StatefulWidget {
  const FanqieHistoryImportPage({super.key, this.collector});

  /// Test seam for the capture service. Production leaves it null and uses the
  /// native login + local backend; the page's progress/cancel wiring is the
  /// same service API either way.
  @visibleForTesting
  final FanqieLibraryCaptureService? collector;

  @override
  State<FanqieHistoryImportPage> createState() =>
      _FanqieHistoryImportPageState();
}

class _FanqieHistoryImportPageState extends State<FanqieHistoryImportPage> {
  final _service = FanqieHistoryImportService();
  late final _collector = widget.collector ?? FanqieLibraryCaptureService();
  FanqieLibraryCapture? _capture;
  final _libraryImporter = FanqieLibraryImportService();
  FanqieImportPreview? _libraryPreview;
  String? _captureProgress;
  BackendRequest? _request;
  bool _error = false;
  bool _loadingLatest = true;
  String _previewSource = '最近采集';
  bool _busy = false;
  String? _message;

  /// Expanded state of the capture details block; the page owns it so a shell
  /// switch or a scroll-out does not collapse the block.
  bool _captureExpanded = false;
  final _previewKey = GlobalKey();
  final _messageKey = GlobalKey();

  /// One list for both presentations, so the shell switch keeps the scroll
  /// position and the visible section can be re-anchored.
  final _scroll = ScrollController();
  late final _anchor = SettingsScrollAnchor(_scroll);

  @override
  void initState() {
    super.initState();
    if (isLinuxDesktop) {
      _loadingLatest = false;
    } else {
      unawaited(_loadLatest());
    }
  }

  @override
  void dispose() {
    _cancelRead();
    _anchor.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _cancelRead() {
    if (_request == null) return;
    _request!.cancel();
    unawaited(_service.cancelLogin());
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
          MissingPluginException() =>
            isLinuxDesktop
                ? '当前环境无法选择文件，请检查桌面文件选择器后重试'
                : '当前环境不支持此操作，请使用 Android 应用',
          // Never display raw platform/network exceptions containing account data.
          PlatformException() =>
            isLinuxDesktop ? '文件操作未完成，请重试' : '登录或文件操作未完成，请重试',
          _ =>
            isLinuxDesktop
                ? '文件读取或导入未完成，请检查文件后重试。若正在合并，部分记录可能已写入，可重复导入。'
                : '操作未完成，请检查网络后重试。若正在合并，部分记录可能已写入，可重复导入。',
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

  Future<void> _collect() => _run(() async {
    setState(() {
      _libraryPreview = null;
      _captureProgress = '等待你在官方页面完成登录';
    });
    final request = BackendRequest();
    _request = request;
    final scheme = Theme.of(context).colorScheme;
    final capture = await _collector.collect(
      request,
      (message) {
        if (mounted) setState(() => _captureProgress = message);
      },
      dark: scheme.brightness == Brightness.dark,
      // Read the app-level e-ink flag, not the page's WenkuAppearance: this
      // State sits above the ArchiveFeaturePage/WenkuScope that registers the
      // extension, and the native login page needs the real global setting.
      eink: HomePalette.of(context).eink,
    );
    if (mounted) {
      setState(() {
        if (capture != null) _capture = capture;
        _captureProgress = null;
      });
    }
    if (capture == null || capture.sources.isEmpty) {
      if (mounted) setState(() => _message = '采集已取消，未保存新文件');
      return;
    }
    // Keep the in-memory result available for export even if private storage
    // fails. A partial capture is useful evidence and never merges itself.
    try {
      final saved = await _collector.save(capture);
      if (mounted) {
        setState(
          () => _message = saved ? '书架数据已保存，解析后即可预览并导入' : '本机保存未完成，当前数据仍可导出',
        );
      }
    } on PlatformException {
      if (mounted) setState(() => _message = '本机保存失败，当前数据仍可导出');
    }
  });

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
      // The online and file paths stay available if no private capture exists.
    } finally {
      if (mounted) setState(() => _loadingLatest = false);
    }
  }

  Future<void> _logout() => _run(() async {
    await _service.clearSession();
    if (mounted) setState(() => _message = '已退出本应用中的番茄网页登录，已采集的数据仍保留');
  });

  @override
  Widget build(BuildContext context) {
    final style = AppUiScope.of(context);
    final classic = style == AppThemeStyle.classic;
    _anchor.track(style);
    final scheme = Theme.of(context).colorScheme;
    final palette = HomePalette.of(context);
    final parsed = _libraryPreview;
    final capture = _capture;
    final enabled = !_busy && !_loadingLatest;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.7,
      color: classic ? palette.ink : scheme.onSurfaceVariant,
    );
    final subtle = muted.copyWith(
      fontSize: 12,
      color: classic ? palette.muted : scheme.onSurfaceVariant,
    );
    final captureInfo =
        '${capture?.received ?? 0} 个响应已保存 · 无需重新登录'
        '${capture != null && capture.stopReason.isNotEmpty ? ' · 部分采集' : ''}';
    final content = <Widget>[
      KeyedSubtree(
        key: _anchor.keyFor('heading'),
        child: SettingsHeading(
          icon: LucideIcons.book_open,
          title: '书架和进度，一起带回来',
          subtitle: isLinuxDesktop
              ? 'Linux 仅支持导入已保存的番茄历史 JSON，预览后合并到本机书架与历史。'
              : '从番茄读取小说，加入本机书架与历史。有章节记录的书，可以接着读。',
        ),
      ),
      const SizedBox(height: 24),
      KeyedSubtree(
        key: _anchor.keyFor('sources'),
        child: const SettingsSection(
          key: ValueKey('fanqie-sources-section'),
          title: '选择导入来源',
          code: 'MIGRATION / SOURCE',
        ),
      ),
      const SizedBox(height: 14),
      SettingsCard(
        archiveDividers: false,
        children: [
          if (!isLinuxDesktop)
            SettingsActionRow(
              key: const ValueKey('fanqie-collect'),
              icon: CupertinoIcons.globe,
              classicIcon: LucideIcons.globe,
              title: '从番茄账号读取',
              subtitle: '打开官方页面登录，保留本机登录状态',
              enabled: enabled,
              onPressed: _collect,
            ),
          SettingsActionRow(
            key: const ValueKey('fanqie-pick'),
            icon: CupertinoIcons.doc_text,
            classicIcon: LucideIcons.file_input,
            title: '从历史文件导入',
            subtitle: '兼容此前保存的番茄历史 JSON',
            enabled: enabled,
            onPressed: _pick,
          ),
        ],
      ),
      if (_loadingLatest)
        const Padding(
          padding: EdgeInsets.only(top: 20),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (!classic && _busy) ...[
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
        KeyedSubtree(
          key: _anchor.keyFor('capture'),
          child: const SettingsSection(
            title: '最近一次采集',
            code: 'MIGRATION / CAPTURED',
          ),
        ),
        const SizedBox(height: 14),
        SettingsCard(
          classicDividers: false,
          children: [
            if (!classic)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: AppText(
                  captureInfo,
                  style: muted.copyWith(fontSize: 13),
                ),
              ),
            SettingsActionRow(
              key: const ValueKey('fanqie-use-capture'),
              icon: CupertinoIcons.clock,
              classicIcon: LucideIcons.clock,
              title: '使用已保存的书架数据',
              subtitle: classic ? captureInfo : null,
              enabled: enabled,
              onPressed: _prepareLibrary,
            ),
            _captureDetails(capture, classic: classic, muted: muted),
          ],
        ),
      ],
      if (parsed != null) ...[
        const SizedBox(height: 28),
        KeyedSubtree(
          key: _anchor.keyFor('preview'),
          child: SettingsSection(
            key: _previewKey,
            title: '导入预览 · $_previewSource',
            code: 'MIGRATION / PREVIEW',
            subtitle: parsed.records.isEmpty
                ? ''
                : '共 ${parsed.records.length} 本',
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
                  SettingsStats(
                    values: {
                      '小说': parsed.records.length,
                      '章节已定位': parsed.matched,
                      '待重试': parsed.unresolved,
                    },
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '同时加入书架和历史，保留较新的本机阅读位置。',
                    style: muted.copyWith(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text('未取得章节的作品从头开始；已定位的作品从对应章节开头续读。', style: subtle),
                  if (!classic) const SizedBox(height: 16),
                ],
              ),
            ),
            for (final record in parsed.records.take(6))
              // Every preview row carries its data id. The section header
              // above scrolls out of the list's build window while the rows
              // are still on screen, so a header-only anchor cannot restore
              // the viewport position.
              KeyedSubtree(
                key: _anchor.keyFor('preview-book-${_recordKey(record)}'),
                child: _recordRow(record, classic: classic, muted: subtle),
              ),
            if (parsed.records.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  '仅展示前 6 本，导入包含全部 ${parsed.records.length} 本小说',
                  style: subtle,
                ),
              ),
            // Classic keeps the merge action in the fixed bottom bar.
            if (!classic)
              SettingsCardRow(
                classicPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SettingsAction(
                  key: const ValueKey('fanqie-merge'),
                  label: '导入 ${parsed.records.length} 本到书架和历史',
                  onPressed: enabled && parsed.records.isNotEmpty
                      ? _mergeLibrary
                      : null,
                ),
              ),
          ],
        ),
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
        key: _anchor.keyFor('footer'),
        child: Text(
          isLinuxDesktop
              ? 'Linux 仅支持历史 JSON 文件导入，不支持账号读取或最近采集。选择文件后先预览，确认后才合并到本机。'
              : '只读取番茄数据，不向账号写入。网页登录状态保存在本应用中，可在右上角退出；'
                    '导出文件不含登录凭证。',
          style: subtle,
        ),
      ),
    ];
    return PopScope(
      canPop: !_busy,
      child: SettingsArchivePage(
        title: '导入番茄书架',
        code: 'MIGRATION / FANQIE',
        actions: [if (!isLinuxDesktop) _loginActions(enabled)],
        // The pre-#291 page owns a fixed bottom action bar (busy progress or
        // the primary merge action); the archive keeps them inside the page.
        classicBottomBar:
            classic && (_busy || parsed != null || capture != null)
            ? _classicBottomBar(context, parsed: parsed, enabled: enabled)
            : null,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: classic ? 640 : 760),
            child: ListView(
              key: const ValueKey('fanqie-import-scroll'),
              controller: _scroll,
              padding: featurePadding(context),
              children: content,
            ),
          ),
        ),
      ),
    );
  }

  /// Classic fixed action bar: busy progress with cancel, or the primary
  /// action (parse the saved capture / merge the preview).
  Widget _classicBottomBar(
    BuildContext context, {
    required FanqieImportPreview? parsed,
    required bool enabled,
  }) {
    final palette = HomePalette.of(context);
    return SafeArea(
      top: false,
      child: Container(
        color: palette.canvas,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(
                  _captureProgress ?? '正在处理，请稍候…',
                  style: TextStyle(color: palette.ink, fontSize: 13),
                ),
              ),
              if (_request != null)
                TextButton(onPressed: _cancelRead, child: const Text('取消读取')),
            ] else
              DataTransferAction(
                label: parsed == null
                    ? '解析并预览已保存的数据'
                    : '导入 ${parsed.records.length} 本到书架和历史',
                onPressed:
                    enabled && (parsed == null || parsed.records.isNotEmpty)
                    ? parsed == null
                          ? _prepareLibrary
                          : _mergeLibrary
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  /// 采集详情：来源统计与补齐/导出操作，两种展示共用同一批回调。
  Widget _captureDetails(
    FanqieLibraryCapture capture, {
    required bool classic,
    required TextStyle muted,
  }) {
    final palette = HomePalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SettingsDisclosure(
      key: const ValueKey('fanqie-capture-details'),
      title: '采集详情与文件',
      expanded: _captureExpanded,
      onExpandedChanged: (value) => setState(() => _captureExpanded = value),
      children: [
        if (capture.stopReason.isNotEmpty)
          SettingsMessage(message: capture.stopReason, error: true),
        Text(
          '已保存 ${capture.parts.length} 个分卷，失败 ${capture.failed} 个响应。'
          '响应数量不是书籍数量。',
          style: muted.copyWith(fontSize: 12),
        ),
        for (final group in _captureSummary(capture).entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.key,
                    style: TextStyle(
                      color: classic ? palette.ink : scheme.onSurface,
                      fontSize: 12,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    group.value,
                    style: TextStyle(
                      color: classic ? palette.muted : scheme.onSurfaceVariant,
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
            SettingsAction(
              label: '补齐书籍资料',
              icon: LucideIcons.refresh_cw,
              compact: true,
              onPressed: _busy ? null : _resumeMetadata,
            ),
            SettingsAction(
              label: '导出原始数据',
              icon: LucideIcons.download,
              compact: true,
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final saved = await _collector.export(capture);
                      if (mounted) {
                        setState(
                          () => _message = saved ? '原始数据文件已导出' : '已取消导出',
                        );
                      }
                    }),
            ),
          ],
        ),
      ],
    );
  }

  /// Stable identity of one preview record: the imported book id, so a
  /// rebuilt row keeps its [SettingsScrollAnchor] key. The identity hash only
  /// covers a record shape without an id; it is stable for the lifetime of the
  /// parsed list and never collides, so two rows cannot share a [GlobalKey].
  static String _recordKey(Map<String, dynamic> record) =>
      '${record['id'] ?? record['bookId'] ?? identityHashCode(record)}';

  /// 预览里的一本：经典用 ListTile，档案保持自绘行。
  Widget _recordRow(
    Map<String, dynamic> record, {
    required bool classic,
    required TextStyle muted,
  }) {
    final palette = HomePalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final title = (record['title'] as String).isEmpty
        ? '未注明书名'
        : record['title'] as String;
    final subtitle =
        record['ep'] as String? ??
        (record['chapterId'] == null ? '未取得阅读章节' : '打开时重新匹配章节');
    if (classic) {
      return ListTile(
        key: ValueKey('fanqie-record-${_recordKey(record)}'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: _cover(record, soft: palette.soft, icon: palette.muted),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.ink, fontSize: 14),
        ),
        subtitle: Text(subtitle, style: muted),
      );
    }
    return Padding(
      key: ValueKey('fanqie-record-${_recordKey(record)}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          _cover(
            record,
            soft: scheme.surfaceContainerHighest,
            icon: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface, fontSize: 14),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
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
    );
  }

  Widget _loginActions(bool enabled) => PopupMenuButton<String>(
    enabled: enabled,
    tooltip: '登录管理',
    onSelected: (_) => _logout(),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'logout', child: Text('退出网页登录')),
    ],
  );

  Widget _cover(
    Map<String, dynamic> record, {
    required Color soft,
    required Color icon,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(5),
    child: SizedBox(
      width: 34,
      height: 46,
      child: (record['cover'] as String? ?? '').isEmpty
          ? ColoredBox(
              color: soft,
              child: Icon(LucideIcons.book_open, color: icon, size: 18),
            )
          : Image.network(
              record['cover'] as String,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(
                color: soft,
                child: Icon(LucideIcons.book_open, color: icon, size: 18),
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
