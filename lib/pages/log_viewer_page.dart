import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_log.dart';
import '../services/book_txt_export.dart';
import '../services/playlet_share.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_feed_states.dart';
import '../widgets/home/home_sheet.dart';
import '../widgets/logs/log_entry_card.dart';
import '../widgets/logs/log_filter_sheet.dart';
import '../widgets/logs/log_viewer_chrome.dart';
import '../widgets/settings/settings_widgets.dart';

enum _LogAction { copy, exportVisible, exportAll, exportBoth, share, clear }

typedef _EntrySignature = (DateTime, LogLevel, String, String);

// Note: 查看历史时冻结列表，导出复用 TXT 通道；见本地
// .agents/notes/implemented/feature/2026-10-12-log-viewer-redesign.md。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key, this.exportSink = const PlatformTxtSink()});

  final TxtSink exportSink;
  static const Duration rustRefresh = Duration(seconds: 2);

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _pendingEntries = HashSet<LogEntry>.identity();
  LogSource _source = LogSource.app;
  LogFilterSelection _filters = const LogFilterSelection();
  String _query = '';
  bool _playerOnly = false;
  bool _following = true;
  bool _active = true;
  bool _exporting = false;
  bool _rustLoading = false;
  int _sourceGeneration = 0;
  List<LogEntry> _entries = const [];
  List<LogEntry> _displayEntries = const [];
  List<LogEntry> _rustEntries = const [];
  String? _rustText;
  Timer? _rustTimer;
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppLog.instance.revision.addListener(_onAppChanged);
    _entries = AppLog.instance.entries;
    _displayEntries = _entries;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppLog.instance.revision.removeListener(_onAppChanged);
    _rustTimer?.cancel();
    _expiryTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _updateRustPolling();
    if (_active) {
      _onAppChanged();
      _scheduleExpiry();
    } else {
      _expiryTimer?.cancel();
    }
  }

  bool _matches(LogEntry entry) {
    if (_filters.level != null && entry.level != _filters.level) return false;
    if (_playerOnly && entry.tag != 'player-load') return false;
    final window = _filters.timeWindow;
    if (window != null &&
        !entry.time.isAfter(DateTime.now().subtract(window))) {
      return false;
    }
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        entry.tag.toLowerCase().contains(query) ||
        entry.message.toLowerCase().contains(query);
  }

  void _onAppChanged() {
    if (_active && _source == LogSource.app) {
      _acceptEntries(AppLog.instance.entries);
    }
  }

  void _acceptEntries(List<LogEntry> next) {
    final previous = HashSet<LogEntry>.identity()..addAll(_entries);
    setState(() {
      if (!_following) {
        // Length alone misses new entries when the ring buffer is already full.
        _pendingEntries.retainAll(next);
        _pendingEntries.removeWhere((entry) => !_matches(entry));
        _pendingEntries.addAll(
          next.where((entry) => !previous.contains(entry) && _matches(entry)),
        );
      }
      _entries = next;
      if (_following) _refreshDisplay();
    });
  }

  void _refreshDisplay() {
    _displayEntries = _entries.where(_matches).toList();
    _pendingEntries.clear();
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    final window = _filters.timeWindow;
    if (!_active || !_following || window == null || _displayEntries.isEmpty) {
      return;
    }
    final oldest = _displayEntries
        .map((entry) => entry.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = oldest.add(window).difference(DateTime.now());
    _expiryTimer = Timer(
      delay.isNegative
          ? Duration.zero
          : delay + const Duration(milliseconds: 1),
      () {
        if (mounted) setState(_refreshDisplay);
      },
    );
  }

  void _changeFilters(VoidCallback change) {
    setState(() {
      change();
      _refreshDisplay();
    });
    _jumpToLatest();
  }

  void _selectSource(LogSource source) {
    if (_source == source) return;
    ++_sourceGeneration;
    setState(() {
      _source = source;
      if (source == LogSource.rust) _playerOnly = false;
      _entries = source == LogSource.app
          ? AppLog.instance.entries
          : _rustEntries;
      _following = true;
      _refreshDisplay();
    });
    _updateRustPolling();
    _jumpToLatest();
  }

  void _updateRustPolling() {
    _rustTimer?.cancel();
    _rustTimer = null;
    if (!_active || _source != LogSource.rust) return;
    unawaited(_loadRust());
    _rustTimer = Timer.periodic(
      LogViewerPage.rustRefresh,
      (_) => unawaited(_loadRust()),
    );
  }

  Future<void> _loadRust() async {
    if (_rustLoading) return;
    final generation = _sourceGeneration;
    _rustLoading = true;
    try {
      final text = await RustLogSource.read();
      if (!mounted || !_active || generation != _sourceGeneration) return;
      if (text == _rustText) return;
      _rustText = text;
      final lines = text?.split('\n') ?? <String>[];
      // A file terminator is not a stack-trace continuation. Keeping it would
      // change the last entry's identity when the next line arrives.
      while (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }
      final parsed = AppLog.parseLogLines(lines);
      // Reuse unchanged entries so polling preserves expanded rows and does not
      // report the whole file as new. Queues distinguish identical log lines.
      final previous = <_EntrySignature, Queue<LogEntry>>{};
      _EntrySignature signature(LogEntry e) =>
          (e.time, e.level, e.tag, e.message);
      for (final entry in _rustEntries) {
        previous.putIfAbsent(signature(entry), Queue.new).add(entry);
      }
      _rustEntries = [
        for (final entry in parsed)
          if (previous[signature(entry)] case final queue?
              when queue.isNotEmpty)
            queue.removeFirst()
          else
            entry,
      ];
      _acceptEntries(_rustEntries);
    } finally {
      _rustLoading = false;
    }
  }

  void _pauseFollowing() {
    if (!_following) return;
    setState(() => _following = false);
    _expiryTimer?.cancel();
  }

  void _followLatest() {
    setState(() {
      _following = true;
      _refreshDisplay();
    });
    _jumpToLatest();
  }

  void _jumpToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle &&
        notification.metrics.pixels > 24) {
      _pauseFollowing();
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        notification.metrics.pixels > 24) {
      _pauseFollowing();
    }
    return false;
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: formatLogLines(entries)));
      _message('已复制 ${entries.length} 条日志');
    } on PlatformException {
      _message('复制失败，请重试');
    }
  }

  Future<void> _export(
    List<LogEntry> entries,
    LogSource source, {
    required bool all,
  }) async {
    if (_exporting || entries.isEmpty) return;
    setState(() => _exporting = true);
    final now = DateTime.now();
    try {
      final target = await widget.exportSink.saveText(
        fileName: 'fqapp-${source.name}-logs-${now.microsecondsSinceEpoch}.txt',
        text:
            'fqapp ${source.label}日志\n'
            '导出时间：${now.toIso8601String()}\n'
            '范围：${all ? '当前来源全部可用日志' : '当前筛选结果'}\n'
            '共 ${entries.length} 条\n\n${formatLogLines(entries)}',
      );
      _message(
        '已导出 ${entries.length} 条${target.isPublic ? '' : '到应用目录'}：${target.path}',
      );
    } on ExportWriteException catch (error) {
      _message('导出失败：${error.message}');
    } catch (_) {
      _message('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<List<LogEntry>?> _readRustForExport() async {
    final text = await RustLogSource.read();
    if (text == null) return null;
    final lines = text.split('\n');
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return AppLog.parseLogLines(lines);
  }

  Future<void> _exportBoth(List<LogEntry> appEntries) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final now = DateTime.now();
    try {
      // Read the core file at export time: the page may be showing the
      // application source, so the polling cache may not be warm.
      final rustEntries = await _readRustForExport();
      if (!mounted) return;
      if (appEntries.isEmpty && (rustEntries == null || rustEntries.isEmpty)) {
        _message(
          rustEntries == null ? '应用暂无日志，核心日志未获取（文件不存在或读取失败）' : '暂无可导出的应用或核心日志',
        );
        return;
      }
      final coreSummary = rustEntries == null
          ? '未获取（文件不存在或读取失败）'
          : '${rustEntries.length} 条';
      final text =
          'fqapp 应用 + 核心日志\n'
          '导出时间：${now.toIso8601String()}\n'
          '范围：应用与核心全部可用日志，不受筛选影响\n'
          '应用日志：${appEntries.length} 条\n'
          '核心日志：$coreSummary\n\n'
          '===== 应用日志 =====\n'
          '${formatLogLines(appEntries)}\n\n'
          '===== 核心日志 =====\n'
          '${rustEntries == null ? coreSummary : formatLogLines(rustEntries)}\n';
      final target = await widget.exportSink.saveText(
        fileName: 'fqapp-all-logs-${now.microsecondsSinceEpoch}.txt',
        text: text,
      );
      _message(
        '已导出应用 ${appEntries.length} 条 + 核心 $coreSummary'
        '${target.isPublic ? '' : '到应用目录'}：${target.path}',
      );
    } on ExportWriteException catch (error) {
      _message('导出失败：${error.message}');
    } catch (_) {
      _message('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(List<LogEntry> entries, LogSource source) async {
    final text = formatLogLines(entries, maxLines: 500);
    // Large stacks can exceed Android's Intent size even below the entry cap.
    if (text.length > 100000) {
      _message('日志内容较多，请使用 TXT 导出');
      return;
    }
    final outcome = await SharePlusLite.share(
      title: '${source.label}日志',
      text: text,
    );
    _message(outcome == ShareLaunchOutcome.launched ? '已调起分享' : '没有可用的分享应用');
  }

  Future<void> _showActions() async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Freeze both the count and payload when opening the menu, so incoming logs
    // cannot silently change what the user chose to copy/export.
    final visible = List<LogEntry>.of(_displayEntries);
    final all = List<LogEntry>.of(_entries);
    final appAll = List<LogEntry>.of(AppLog.instance.entries);
    final source = _source;
    final action = await showHomeSheet<_LogAction>(
      context: context,
      title: '${source.label}日志',
      children: [
        _sheetHint('导出为 TXT 文件，保留完整内容'),
        _actionRow(
          _LogAction.copy,
          LucideIcons.copy,
          '复制筛选结果',
          '${visible.length} 条 · 当前查看的结果',
          enabled: visible.isNotEmpty,
        ),
        _actionRow(
          _LogAction.exportVisible,
          LucideIcons.download,
          '导出筛选结果',
          '${visible.length} 条 · 保存为 TXT',
          enabled: visible.isNotEmpty && !_exporting,
        ),
        _actionRow(
          _LogAction.exportAll,
          LucideIcons.file_down,
          '导出全部',
          '${all.length} 条 · 当前来源，不受筛选影响',
          enabled: all.isNotEmpty && !_exporting,
        ),
        _actionRow(
          _LogAction.exportBoth,
          LucideIcons.files,
          '导出应用 + 核心',
          '应用 ${appAll.length} 条 + 核心日志 · 导出前读取最新内容',
          // The core may have logs even if its tab has never been opened.
          enabled: !_exporting,
        ),
        _actionRow(
          _LogAction.share,
          LucideIcons.share_2,
          '分享筛选结果',
          visible.length > 500
              ? '仅分享最近 500 条，完整内容请导出 TXT'
              : '${visible.length} 条 · 系统分享',
          enabled: visible.isNotEmpty,
        ),
        Divider(height: 17, color: HomePalette.of(context).line),
        _actionRow(
          _LogAction.clear,
          LucideIcons.trash,
          '清空当前视图',
          source == LogSource.app ? '保留已保存的日志文件' : '核心日志由服务维护，不支持清空',
          enabled: source == LogSource.app && all.isNotEmpty,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _LogAction.copy:
        await _copy(visible);
      case _LogAction.exportVisible:
        await _export(visible, source, all: false);
      case _LogAction.exportAll:
        await _export(all, source, all: true);
      case _LogAction.exportBoth:
        await _exportBoth(appAll);
      case _LogAction.share:
        await _share(visible, source);
      case _LogAction.clear:
        await _confirmClear();
    }
  }

  Widget _sheetHint(String text) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: palette.muted)),
    );
  }

  Widget _actionRow(
    _LogAction action,
    IconData icon,
    String title,
    String subtitle, {
    required bool enabled,
  }) => SettingsRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    enabled: enabled,
    showChevron: false,
    onTap: enabled ? () => Navigator.pop(context, action) : null,
  );

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空当前视图'),
        content: const Text('清空当前可查看的应用日志，保留已保存的日志文件。重启后可能再次显示历史记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    AppLog.instance.clear();
    // Clearing is explicit even while the list is paused.
    setState(_refreshDisplay);
  }

  Future<void> _pickFilters() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showHomeSheet<LogFilterSelection>(
      context: context,
      title: '筛选日志',
      children: [LogFilterSheet(initial: _filters)],
    );
    if (!mounted || result == null) return;
    _changeFilters(() => _filters = result);
  }

  void _togglePlayerOnly(bool selected) {
    if (selected) _selectSource(LogSource.app);
    _changeFilters(() => _playerOnly = selected);
  }

  void _clearLevel() => _changeFilters(
    () => _filters = LogFilterSelection(timeWindow: _filters.timeWindow),
  );

  void _clearTimeWindow() => _changeFilters(
    () => _filters = LogFilterSelection(level: _filters.level),
  );

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final indices = <Key, int>{
      for (var i = 0; i < _displayEntries.length; i++)
        ObjectKey(_displayEntries[i]): _displayEntries.length - 1 - i,
    };
    return SettingsScaffold(
      title: '日志',
      actions: [
        IconButton(
          tooltip: '日志操作',
          onPressed: _exporting ? null : _showActions,
          icon: Icon(
            LucideIcons.ellipsis,
            color: _exporting
                ? palette.muted.withValues(alpha: 0.4)
                : palette.ink,
          ),
        ),
      ],
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            LogToolbar(
              controller: _searchController,
              query: _query,
              source: _source,
              playerOnly: _playerOnly,
              filters: _filters,
              onQueryChanged: (value) => _changeFilters(() => _query = value),
              onPickFilters: _pickFilters,
              onSelectSource: _selectSource,
              onTogglePlayerOnly: _togglePlayerOnly,
              onClearLevel: _clearLevel,
              onClearTimeWindow: _clearTimeWindow,
            ),
            if (_exporting)
              LinearProgressIndicator(
                minHeight: 2,
                color: palette.accentText,
                backgroundColor: palette.line,
              ),
            Expanded(
              child: _displayEntries.isEmpty
                  ? _buildEmpty()
                  : NotificationListener<ScrollNotification>(
                      onNotification: _onScroll,
                      child: ListView.builder(
                        key: const ValueKey('log-list'),
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _displayEntries.length,
                        findChildIndexCallback: (key) => indices[key],
                        itemBuilder: (context, index) {
                          final entry =
                              _displayEntries[_displayEntries.length -
                                  1 -
                                  index];
                          return LogEntryCard(
                            key: ObjectKey(entry),
                            entry: entry,
                            onCopy: () => _copy([entry]),
                          );
                        },
                      ),
                    ),
            ),
            LogFollowBar(
              count: _displayEntries.length,
              following: _following,
              pendingCount: _pendingEntries.length,
              onToggle: _following ? _pauseFollowing : _followLatest,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final filtered =
        _query.trim().isNotEmpty ||
        _playerOnly ||
        _filters.level != null ||
        _filters.timeWindow != null;
    return HomeStateView(
      icon: filtered ? LucideIcons.search_x : LucideIcons.receipt_text,
      title: filtered
          ? '没有匹配的日志'
          : _source == LogSource.app
          ? '暂无日志'
          : '暂无核心日志',
      message: filtered ? '试试其他关键词，或调整筛选条件' : '运行应用后，日志会显示在这里',
      scrollable: true,
    );
  }
}
