import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_client.dart';
import '../services/backend_service.dart';
import '../widgets/home/home_design.dart';
import 'log_viewer_page.dart';

/// 服务详情页：把原来分散在「服务」分类下的三项（本地后端、服务状态、日志）
/// 整合成一页：状态自检、用途说明、服务地址、日志入口。
class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({super.key, this.healthCheck});

  /// 注入健康检查，便于测试；默认走真实后端 `/health`。
  final Future<bool> Function()? healthCheck;

  @override
  State<ServiceDetailPage> createState() => _ServiceDetailPageState();
}

enum _BackendStatus { checking, running, stopped }

class _ServiceDetailPageState extends State<ServiceDetailPage> {
  _BackendStatus _status = _BackendStatus.checking;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _status = _BackendStatus.checking);
    final check = widget.healthCheck ?? ApiClient.instance.health;
    final ok = await check();
    if (!mounted) return;
    setState(
      () => _status = ok ? _BackendStatus.running : _BackendStatus.stopped,
    );
  }

  /// Opens the built-in Web UI in a browser.
  ///
  /// The transport's `resourceBase` carries the loopback capability in its
  /// path; the adapter answers that entry with a redirect to `/` plus the
  /// session cookie, so the capability never lingers in the address bar.
  Future<void> _openWebUi(BuildContext context) async {
    final entry = BackendService.instance.webUiEntryUrl;
    if (entry.isEmpty) return;
    var launched = false;
    try {
      // Android package visibility may hide a browser from canLaunchUrl even
      // though it can handle the actual ACTION_VIEW intent.
      launched = await launchUrl(
        Uri.parse(entry),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Report launch failures through the same visible fallback.
    }
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开 Web UI')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final checking = _status == _BackendStatus.checking;
    final running = _status == _BackendStatus.running;
    final statusText = switch (_status) {
      _BackendStatus.checking => '检查中…',
      _BackendStatus.running => '运行中',
      _BackendStatus.stopped => '已停止',
    };
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('服务'),
        centerTitle: true,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              '本地后端为 Web UI 与漫画图提供服务，仅本机可访问，不对外暴露。',
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
          Material(
            color: palette.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.line, width: 0.6),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: checking
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            running
                                ? LucideIcons.circle_check
                                : LucideIcons.circle_alert,
                            color: running ? Colors.green : Colors.red,
                          ),
                    title: const Text('本地后端'),
                    subtitle: Text(statusText),
                    trailing: IconButton(
                      icon: const Icon(LucideIcons.rotate_ccw, size: 18),
                      tooltip: '重新检查',
                      onPressed: checking ? null : _refresh,
                    ),
                  ),
                  Divider(height: 1, indent: 68, color: palette.line),
                  ListTile(
                    leading: const Icon(LucideIcons.globe),
                    title: const Text('服务地址'),
                    subtitle: Text(BackendService.instance.baseUrl),
                    trailing: const Icon(LucideIcons.square_arrow_out_up_right,
                        size: 18),
                    onTap: () => _openWebUi(context),
                  ),
                  Divider(height: 1, indent: 68, color: palette.line),
                  ListTile(
                    leading: const Icon(LucideIcons.terminal),
                    title: const Text('日志'),
                    subtitle: const Text('查看应用运行日志'),
                    trailing: Icon(
                      LucideIcons.chevron_right,
                      size: 18,
                      color: palette.muted,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LogViewerPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
