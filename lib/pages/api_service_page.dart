import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/backend_service.dart';
import '../services/lan_share_preferences.dart';
import '../widgets/home/home_design.dart';
import 'log_viewer_page.dart';

/// Local API service console.
///
/// The backend exposes a read-only HTTP API on loopback so external readers
/// (Legado book sources, local tooling) can consume it. There is no built-in
/// Web UI any more: this page is the only place the interface is described.
///
/// Deliberately short. Three things matter here — is it running, what address
/// do I paste elsewhere, and let me check that address actually answers. The
/// endpoint list is a reference, so it stays collapsed until asked for.
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
  bool _showEndpoints = false;

  /// Device-pool size reported by `/health`; null until the first answer.
  int? _devices;

  /// Result of the manual connectivity check, null when never run.
  String? _probeResult;
  bool _probeOk = false;

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

  /// Reads `/health` once and keeps both the verdict and the device count.
  ///
  /// The count is the only real signal `/health` carries, so showing「运行中」
  /// alone threw it away. It does not touch upstream or the device pool's
  /// rotating budget, which is why the probe uses it instead of a search.
  Future<void> _refresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    int? devices;
    var ok = false;
    try {
      final base = BackendService.instance.baseUrl;
      final response = await BackendService.instance.transport
          .send('GET', Uri.parse('$base/health'), timeout: const Duration(seconds: 3));
      if (response.statusCode == 200) {
        ok = true;
        try {
          final decoded = jsonDecode(utf8.decode(response.body));
          if (decoded is Map && decoded['devices'] is num) {
            devices = (decoded['devices'] as num).toInt();
          }
        } catch (_) {
          // A body we cannot parse still proves the listener answered.
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _status = ok ? '运行中' : '已停止';
      _devices = devices;
      _checking = false;
    });
  }

  /// Explicit self-test: reports what the client actually got back.
  ///
  /// [refresh] keeps the row's own state quiet; this one is a deliberate action
  /// so it is allowed to say "通了 / 不通" out loud.
  Future<void> _probe() async {
    if (_checking) return;
    setState(() => _checking = true);
    String result;
    var ok = false;
    try {
      final base = BackendService.instance.baseUrl;
      final response = await BackendService.instance.transport.send(
        'GET',
        Uri.parse('$base/health'),
        timeout: const Duration(seconds: 5),
      );
      ok = response.statusCode == 200;
      result = ok ? '通了 · HTTP 200' : '返回 HTTP ${response.statusCode}';
      if (ok) {
        try {
          final decoded = jsonDecode(utf8.decode(response.body));
          if (decoded is Map && decoded['devices'] is num) {
            result = '通了 · HTTP 200 · ${(decoded['devices'] as num).toInt()} 个设备';
          }
        } catch (_) {}
      }
    } catch (error) {
      result = '不通 · $error';
    }
    if (!mounted) return;
    setState(() {
      _probeOk = ok;
      _probeResult = result;
      _checking = false;
    });
    await _refresh();
  }

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
      // The status row below reports it after the refresh.
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
    // 相对路径：根地址已经在上面的卡片里，这里再拼一遍只会让列表更难读。
    const endpoints = <(String, String, String)>[
      ('搜索', '/api/v1/search/fanqie?query=', '替换为关键词'),
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // 状态：一行说完「跑没跑 + 几个设备 + 要不要再测一次」。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: healthy ? const Color(0xFF22C55E) : palette.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _devices == null ? _status : '$_status · $_devices 个设备',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _checking ? null : _probe,
                  icon: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.activity, size: 16),
                  label: const Text('自测'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          if (_probeResult != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, bottom: 8),
              child: Text(
                _probeResult!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _probeOk
                      ? const Color(0xFF16A34A)
                      : theme.colorScheme.error,
                ),
              ),
            ),

          // 地址 + 局域网开关：两者都是「怎么访问」，合成一块。
          _card(
            palette: palette,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _addressRow(
                  palette: palette,
                  theme: theme,
                  label: _lanShare ? '本机' : '地址',
                  value: _base,
                ),
                Divider(height: 20, color: palette.line),
                InkWell(
                  onTap: _switching ? null : () => _toggleLanShare(!_lanShare),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          _lanShare
                              ? LucideIcons.wifi
                              : LucideIcons.wifi_off,
                          size: 16,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '局域网共享',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.ink,
                          ),
                        ),
                        const Spacer(),
                        if (_switching)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Switch(
                            value: _lanShare,
                            onChanged: _switching ? null : _toggleLanShare,
                          ),
                      ],
                    ),
                  ),
                ),
                if (_lanShare) ...[
                  if (_lanAddresses.isEmpty)
                    Text(
                      '未检测到局域网地址，请确认已连接 WiFi。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.muted,
                      ),
                    )
                  else
                    for (final ip in _lanAddresses)
                      _addressRow(
                        palette: palette,
                        theme: theme,
                        label: '局域网',
                        value: 'http://$ip:$_listenPort',
                      ),
                  const SizedBox(height: 4),
                  Text(
                    '无密码，同一网络下任何设备都能读取。公共 WiFi 建议关闭。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 接口是参考信息，默认收起；要用的人自己点开。
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () =>
                setState(() => _showEndpoints = !_showEndpoints),
            icon: Icon(
              _showEndpoints
                  ? LucideIcons.chevron_down
                  : LucideIcons.chevron_right,
              size: 16,
              color: palette.muted,
            ),
            label: Text(
              _showEndpoints ? '隐藏接口' : '查看可用接口',
              style: TextStyle(color: palette.muted),
            ),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (_showEndpoints)
            _card(
              palette: palette,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < endpoints.length; i++) ...[
                    if (i > 0) Divider(height: 18, color: palette.line),
                    _endpointRow(
                      palette: palette,
                      theme: theme,
                      name: endpoints[i].$1,
                      path: endpoints[i].$2,
                      hint: endpoints[i].$3,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '路径拼在上面的地址后面；{ } 内是变量，需替换成实际 ID。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 8),
          _card(
            palette: palette,
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogViewerPage()),
              ),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(LucideIcons.terminal, size: 18, color: palette.muted),
                    const SizedBox(width: 10),
                    Text(
                      '运行日志',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.ink,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 16,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required HomePalette palette, required Widget child}) =>
      Material(
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

  /// One copyable address line: label, address, copy affordance.
  Widget _addressRow({
    required HomePalette palette,
    required ThemeData theme,
    required String label,
    required String value,
  }) {
    return InkWell(
      onTap: value.isEmpty ? null : () => _copy('地址', value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.muted,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value.isEmpty ? '等待服务启动' : value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.ink,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            Icon(LucideIcons.copy, size: 15, color: palette.muted),
          ],
        ),
      ),
    );
  }

  /// One endpoint: name, relative path, one-line purpose.
  Widget _endpointRow({
    required HomePalette palette,
    required ThemeData theme,
    required String name,
    required String path,
    required String hint,
  }) {
    return InkWell(
      onTap: () => _copy(name, '$_base$path'),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'GET',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              path,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.ink,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: palette.muted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
