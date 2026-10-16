import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/api_client.dart';
import '../widgets/home/home_design.dart';
import 'log_viewer_page.dart';

/// 服务详情页：把原来分散在「服务」分类下的三项（本地后端、服务状态、日志）
/// 整合成一页：状态自检、用途说明、日志入口。本地后端在应用进程内运行，
/// 不监听任何端口，别的 App 无法访问。
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
              '本地后端在应用进程内运行，为漫画图提供服务，不监听任何端口，别的 App 无法访问。',
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
