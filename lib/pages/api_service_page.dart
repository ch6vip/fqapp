import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/api_client.dart';
import '../services/backend_service.dart';
import '../services/lan_share_preferences.dart';
import '../widgets/home/home_design.dart';
import 'log_viewer_page.dart';

/// Local API service console.
///
/// The backend exposes a read-only HTTP API on loopback so external readers
/// (Legado book sources, local tooling) can consume it. There is no built-in
/// Web UI any more: this page is the only place the interface is described,
/// and every address here is copy-paste ready.
class ApiServicePage extends StatefulWidget {
  const ApiServicePage({super.key});

  @override
  State<ApiServicePage> createState() => _ApiServicePageState();
}

class _ApiServicePageState extends State<ApiServicePage> {
  String _status = '';
  bool _checking = false;
  bool _switching = false;
  bool _lanShare = false;
  /// LAN addresses of this device, most likely WiFi first. Empty while sharing
  /// is off or the lookup failed.
  List<String> _lanAddresses = const [];

  @override
  void initState() {
    super.initState();
    _loadShareState();
    _refresh();
  }

  Future<void> _loadShareState() async {
    await LanSharePreferences.instance.load();
    final enabled = LanSharePreferences.instance.enabled.value;
    final addresses = enabled ? await _detectLanAddresses() : const <String>[];
    if (!mounted) return;
    setState(() {
      _lanShare = enabled;
      _lanAddresses = addresses;
    });
  }

  /// IPv4 addresses of up-link interfaces.
  ///
  /// `NetworkInterface.list` enumerates every interface, including loopback and
  /// (on Android) cellular/tunnel ones. Only usable LAN addresses are useful to
  /// show, so link-local and loopback are filtered out and the result is
  /// ordered with private ranges first.
  static Future<List<String>> _detectLanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final found = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) found.add(address.address);
        }
      }
      found.sort((a, b) {
        int rank(String ip) => ip.startsWith('192.168.')
            ? 0
            : ip.startsWith('10.')
            ? 1
            : ip.startsWith('172.')
            ? 2
            : 3;
        return rank(a).compareTo(rank(b));
      });
      return found;
    } catch (_) {
      return const [];
    }
  }

  /// Toggles LAN sharing: confirm, persist, rebuild the listener, re-read what
  /// the core is actually bound to.
  Future<void> _toggleLanShare(bool value) async {
    if (_switching) return;
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('开启局域网共享'),
          content: const Text(
            '同一网络下的其他设备将能访问这些接口，无需密码。\n\n'
            '开启后本地服务会重启，正在进行的请求会中断一次。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('开启'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() => _switching = true);
    await LanSharePreferences.instance.setEnabled(value);
    try {
      await BackendService.instance.restartForListenMode();
    } catch (_) {
      // The core is down; the status row below reports it after the refresh.
    }
    final addresses = value ? await _detectLanAddresses() : const <String>[];
    if (!mounted) return;
    setState(() {
      _lanShare = value;
      _lanAddresses = addresses;
      _switching = false;
    });
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await ApiClient.instance.health();
    if (!mounted) return;
    setState(() {
      _status = ok ? '运行中' : '已停止';
      _checking = false;
    });
  }

  String get _base {
    final base = BackendService.instance.baseUrl;
    return base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
  }

  /// Port the core is bound to, taken from [baseUrl] so the LAN rows and the
  /// loopback row cannot disagree.
  String get _listenPort {
    final parts = Uri.tryParse(_base);
    if (parts == null || parts.port == 0) return '';
    return '${parts.port}';
  }

  Future<void> _copy(String label, String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final theme = Theme.of(context);
    final healthy = _status == '运行中';
    // Read-only endpoints a book source needs, in call order.
    final endpoints = <(String, String, String)>[
      ('搜索', '/api/v1/search/fanqie?query=关键词', '返回各内容分组的搜索结果'),
      ('详情', '/api/v1/books/{book_id}', '书名、作者、简介、封面'),
      ('目录', '/api/v1/books/{book_id}/directory', '章节列表'),
      ('正文', '/api/v1/chapters/{item_id}', '章节正文与插图'),
    ];

    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('本地接口'),
        centerTitle: true,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _card(
            palette: palette,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      healthy
                          ? LucideIcons.circle_check
                          : LucideIcons.circle_alert,
                      size: 18,
                      color: healthy ? Colors.green : Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '服务状态',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _status,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: _checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.rotate_ccw, size: 18),
                      onPressed: _checking ? null : _refresh,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _lanShare
                      ? '已对局域网开放，同一网络下的设备可访问。'
                      : '接口只监听本机回环地址，其他设备无法访问。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            palette: palette,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _lanShare,
                  onChanged: _switching ? null : _toggleLanShare,
                  title: const Text('局域网共享'),
                  subtitle: Text(
                    _switching ? '正在重启本地服务…' : '允许同一网络下的其他设备访问这些接口',
                  ),
                ),
                if (_lanShare) ...[
                  const SizedBox(height: 4),
                  if (_lanAddresses.isEmpty)
                    Text(
                      '未检测到局域网地址，请确认已连接 WiFi。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    )
                  else
                    for (final ip in _lanAddresses) ...[
                      _copyRow(
                        context,
                        palette: palette,
                        theme: theme,
                        label: '局域网',
                        value: 'http://$ip:$_listenPort',
                      ),
                    ],
                  const SizedBox(height: 4),
                  Text(
                    '同一网络、无密码，任何设备都能读取这些接口。'
                    '在公共 WiFi 下建议关闭。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            palette: palette,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '接口地址',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                _copyRow(
                  context,
                  palette: palette,
                  theme: theme,
                  label: _lanShare ? '本机' : '根地址',
                  value: _base,
                ),
                const SizedBox(height: 4),
                Text(
                  '在阅读（Legado）等支持自定义书源的软件里，把上面的地址'
                  '作为书源请求前缀使用。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            palette: palette,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '可用接口',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '以下路径拼在根地址后面。{ } 内的部分是变量，需替换成实际 ID。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                for (final (name, path, hint) in endpoints) ...[
                  const SizedBox(height: 10),
                  _copyRow(
                    context,
                    palette: palette,
                    theme: theme,
                    label: name,
                    value: '$_base$path',
                    hint: hint,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            palette: palette,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(LucideIcons.terminal, size: 20),
              title: const Text('日志'),
              subtitle: const Text('查看应用运行日志'),
              trailing: const Icon(LucideIcons.chevron_right, size: 18),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogViewerPage()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required HomePalette palette,
    required Widget child,
  }) => Material(
    color: palette.surface,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    ),
  );

  Widget _copyRow(
    BuildContext context, {
    required HomePalette palette,
    required ThemeData theme,
    required String label,
    required String value,
    String? hint,
  }) {
    return InkWell(
      onTap: value.isEmpty ? null : () => _copy(label, value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value.isEmpty ? '等待服务启动' : value,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (hint != null)
                    Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              LucideIcons.copy,
              size: 16,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
