import 'package:flutter/material.dart';

import '../../../models/media_item.dart';
import '../../../services/ai_reading/ai_chapter_snapshot.dart';
import '../../../services/ai_reading/ai_controller.dart';
import '../../../services/ai_reading/ai_feedback.dart';
import '../../../services/ai_reading/ai_models.dart';
import '../../../services/ai_reading/ai_store.dart';
import '../../../services/chapter_text_formatter.dart';
import '../../../services/imported_book_store.dart';
import '../../../widgets/ai_reading/ai_ui.dart';
import '../../../widgets/home/home_design.dart';
import '../../../widgets/settings/settings_widgets.dart';
import 'ai_settings_widgets.dart';

/// Pending feedback assets from local books whose book/chapter ids changed.
/// A chapter is selected from the currently imported book; binding is allowed
/// only when its canonical body hash and every stored source offset match.
class AiLocalRebindPage extends StatefulWidget {
  const AiLocalRebindPage({super.key, this.bookId, this.title});

  final String? bookId;
  final String? title;

  @override
  State<AiLocalRebindPage> createState() => _AiLocalRebindPageState();
}

class _AiLocalRebindPageState extends State<AiLocalRebindPage> {
  List<AiPendingBinding> _bindings = const [];
  List<Chapter> _chapters = const [];
  Chapter? _chapter;
  AiChapterSnapshot? _snapshot;
  bool _loading = true;
  bool _snapshotLoading = false;
  String? _error;
  String? _snapshotError;
  String? _busyBindingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AiReadingController.instance.init();
      final bindings = await AiStore.instance.pendingBindings();
      bindings.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      var chapters = const <Chapter>[];
      final bookId = widget.bookId;
      if (bookId != null && bookId.startsWith('local_')) {
        final book = await ImportedBookStore.instance.book(bookId);
        chapters = book?.chapters ?? const [];
      }
      if (!mounted) return;
      final previous = _chapter?.itemId;
      setState(() {
        _bindings = bindings;
        _chapters = chapters;
        _chapter = chapters.isEmpty
            ? null
            : chapters.firstWhere(
                (chapter) => chapter.itemId == previous,
                orElse: () => chapters.first,
              );
        _loading = false;
      });
      if (_chapter != null) {
        await _loadSnapshot(_chapter!);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _loadSnapshot(Chapter chapter) async {
    final bookId = widget.bookId;
    if (bookId == null) return;
    setState(() {
      _snapshotLoading = true;
      _snapshotError = null;
      _snapshot = null;
    });
    try {
      final text = await ImportedBookStore.instance.chapterText(
        bookId,
        chapter.itemId,
      );
      final content = ChapterContent.fromPlainText(text);
      final snapshot = AiChapterSnapshotBuilder.fromContent(
        content,
        chapter.title,
      );
      if (!mounted || _chapter?.itemId != chapter.itemId) return;
      setState(() {
        _snapshot = snapshot;
        _snapshotLoading = false;
      });
    } catch (error) {
      if (!mounted || _chapter?.itemId != chapter.itemId) return;
      setState(() {
        _snapshotLoading = false;
        _snapshotError = '$error';
      });
    }
  }

  Future<void> _pickChapter() async {
    if (_chapters.isEmpty) return;
    final picked = await showModalBottomSheet<Chapter>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final palette = HomePalette.of(context);
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.72,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '选择章节',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = _chapters[index];
                      final selected = chapter.itemId == _chapter?.itemId;
                      return ListTile(
                        title: Text(
                          chapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected
                            ? const Icon(Icons.check, color: HomePalette.accent)
                            : null,
                        onTap: () => Navigator.of(context).pop(chapter),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _chapter = picked);
    await _loadSnapshot(picked);
  }

  bool _matches(AiPendingBinding binding) {
    final snapshot = _snapshot;
    if (snapshot == null) return false;
    if (binding.canonicalHash != snapshot.canonicalHash ||
        binding.canonicalVersion != snapshot.canonicalVersion) {
      return false;
    }
    return AiFeedbackService.aggregateFitsSnapshot(binding.aggregate, snapshot);
  }

  Future<void> _bind(AiPendingBinding binding) async {
    final bookId = widget.bookId;
    final chapter = _chapter;
    final snapshot = _snapshot;
    if (bookId == null || chapter == null || snapshot == null) return;
    if (!_matches(binding)) {
      aiShowSnack(context, '当前章节正文哈希不匹配，不能绑定');
      return;
    }
    final existing = await AiStore.instance.aggregate(
      bookId: bookId,
      chapterId: chapter.itemId,
      canonicalVersion: snapshot.canonicalVersion,
      canonicalHash: snapshot.canonicalHash,
    );
    if (existing != null) {
      if (!mounted) return;
      aiShowSnack(context, '本章已有反馈，请先在反馈管理里处理');
      return;
    }
    if (!mounted) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '绑定到本章？',
      message:
          '将把 ${binding.aggregate.cases.length} 条反馈、'
          '${binding.aggregate.protections.length} 条保护绑定到「${chapter.title}」。'
          '绑定只建立章节映射，不会改写正文。',
      confirmLabel: '确认绑定',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyBindingId = binding.id);
    try {
      final aggregate = AiFeedbackService.rebindAggregate(
        aggregate: binding.aggregate,
        bookId: bookId,
        chapterId: chapter.itemId,
      );
      await AiStore.instance.putAggregate(aggregate);
      await AiStore.instance.deletePending(binding.id);
      AiReadingController.instance.notifyExternalDataChanged();
      if (!mounted) return;
      aiShowSnack(context, '已绑定到「${chapter.title}」');
      await _load();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '绑定失败：$error');
    } finally {
      if (mounted) setState(() => _busyBindingId = null);
    }
  }

  Future<void> _delete(AiPendingBinding binding) async {
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除这条待处理记录？',
      message: '删除后无法自动重新定位这段反馈，且不可恢复。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await AiStore.instance.deletePending(binding.id);
      if (!mounted) return;
      aiShowSnack(context, '已删除');
      await _load();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '删除失败：$error');
    }
  }

  Future<void> _deleteAll() async {
    if (_bindings.isEmpty) return;
    final confirmed = await showSettingsConfirmDialog(
      context: context,
      title: '删除全部待处理记录？',
      message: '共 ${_bindings.length} 条，删除后不可恢复。',
      confirmLabel: '全部删除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      for (final binding in _bindings) {
        await AiStore.instance.deletePending(binding.id);
      }
      if (!mounted) return;
      aiShowSnack(context, '已删除全部待处理记录');
      await _load();
    } catch (error) {
      if (!mounted) return;
      aiShowSnack(context, '删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SettingsScaffold(
      title: '本地书待绑定',
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '待处理记录读取失败',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _error ?? '',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: palette.muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (_chapters.isNotEmpty) ...[
                  const SettingsSectionHeader(title: '匹配章节'),
                  const SizedBox(height: 8),
                  SettingsGroupCard(
                    children: [
                      SettingsRow(
                        icon: Icons.menu_book_outlined,
                        title: '当前章节',
                        subtitle: _snapshotLoading
                            ? '正在校验正文…'
                            : _snapshotError != null
                            ? '正文读取失败'
                            : _chapter?.title ?? '未选择',
                        value: '选择',
                        onTap: _pickChapter,
                      ),
                    ],
                  ),
                ],
                if (_bindings.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: AiInfoCard(
                      title: '没有待处理记录',
                      body: '本地书换设备或重新导入后，旧反馈会出现在这里。',
                      icon: Icons.check_circle_outline,
                      tone: AiStatusTone.ok,
                    ),
                  )
                else ...[
                  const SizedBox(height: 16),
                  const SettingsSectionHeader(title: '待处理'),
                  const SizedBox(height: 8),
                  SettingsGroupCard(
                    children: [
                      for (final binding in _bindings)
                        SettingsRow(
                          title: binding.title.isEmpty
                              ? '未命名章节'
                              : binding.title,
                          subtitle:
                              '来源章节 ${binding.sourceChapterId}，'
                              '用例 ${binding.aggregate.cases.length} 条，'
                              '${aiFormatDateTime(binding.createdAt)}',
                          trailing: _bindingTrailing(binding, palette),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.ink,
                    side: BorderSide(color: palette.line),
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: const Text('暂不绑定'),
                ),
                if (_bindings.isNotEmpty)
                  TextButton(
                    onPressed: _deleteAll,
                    child: const Text('删除全部待处理'),
                  ),
              ],
            ),
    );
  }

  Widget _bindingTrailing(AiPendingBinding binding, HomePalette palette) {
    if (_snapshotLoading || _busyBindingId == binding.id) {
      return const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final delete = IconButton(
      tooltip: '删除待处理记录',
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.delete_outline, size: 20, color: palette.muted),
      onPressed: () => _delete(binding),
    );
    if (_chapter == null || !_matches(binding)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('不匹配', style: TextStyle(fontSize: 12.5, color: palette.muted)),
          delete,
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: () => _bind(binding), child: const Text('绑定')),
        delete,
      ],
    );
  }
}
