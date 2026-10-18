import 'package:flutter/services.dart';

import '../models/fanqie_history.dart';
import 'api_client.dart';
import 'backend_transport.dart';
import 'fanqie_library_import_service.dart';

class FanqieHistoryImportService {
  static const _account = MethodChannel('fqapp/fanqie_account');
  static const _files = MethodChannel('fqapp/library_backup');

  Future<FanqieHistoryPreview?> loginAndFetch(BackendRequest request) async {
    final cookie = await _account.invokeMethod<String>('login');
    if (request.isCancelled) throw BackendRequestAborted('请求已取消');
    if (cookie == null || cookie.isEmpty) return null;
    return ApiClient.instance.withCancellation(request, () async {
      var offset = 0;
      var count = 0;
      String? deviceId;
      final records = <Map<String, dynamic>>[];
      for (var index = 0; index < 200; index++) {
        if (request.isCancelled) throw BackendRequestAborted('请求已取消');
        Map<String, dynamic> envelope;
        try {
          envelope = await ApiClient.instance.fanqieHistoryPage(
            cookie: cookie,
            offset: offset,
            lastMinReadTimestampMs: 0,
            // The inspected official caller keeps this flag for the whole run.
            firstLoad: true,
            deviceId: deviceId,
          );
        } on ApiException catch (error) {
          // Only fixed messages authored by this local adapter may reach UI.
          const safeMessages = {
            '历史读取参数无效或过长',
            '历史读取参数无效',
            '未取得有效登录态，请重新在官方页面登录',
            '读取历史所需设备不可用，请重新开始导入',
            '无法初始化历史读取连接',
            '无法连接番茄历史接口，请稍后重试',
            '番茄未接受历史读取请求，网页登录态可能不兼容 App 接口',
            '番茄历史响应过大，已停止读取',
            '番茄历史响应格式不受支持',
            '读取历史未获授权，请重新登录；网页账号可能无法读取 App 历史',
            '响应未包含历史列表，未将其当作空历史导入',
          };
          if (safeMessages.contains(error.message)) {
            throw FormatException(error.message);
          }
          rethrow;
        }
        final selectedDevice = envelope['_fqapp_device_id'];
        if (selectedDevice is! String ||
            selectedDevice.isEmpty ||
            (deviceId != null && selectedDevice != deviceId)) {
          throw const FormatException('历史读取设备发生变化，请重新开始导入');
        }
        deviceId ??= selectedDevice;
        final page = FanqieHistoryPage.parse(envelope);
        if (request.isCancelled) throw BackendRequestAborted('请求已取消');
        count += page.sourceCount;
        if (count > 10000) throw const FormatException('历史超过 10000 条，未导入');
        records.addAll(page.records);
        if (!page.hasMore) {
          if (count == 0) {
            throw const FormatException('接口返回空历史，暂不能区分账号没有记录或网页登录态不兼容；未写入本机');
          }
          return FanqieHistoryPreview.fromRecords(records, count);
        }
        if (page.sourceCount == 0 || page.nextOffset <= offset) {
          throw const FormatException('历史分页未前进，已停止；尚未写入本机');
        }
        offset = page.nextOffset;
      }
      throw const FormatException('历史分页超过 200 页，未导入');
    });
  }

  Future<FanqieHistoryPreview?> pickFile() async {
    final bytes = await _files.invokeMethod<Uint8List>('openBackup');
    return bytes == null ? null : FanqieHistoryPreview.fromBytes(bytes);
  }

  Future<int> merge(FanqieHistoryPreview preview) async {
    final records = [
      for (final record in preview.validated.history)
        {...record, 'author': record['author'] ?? '', 'fanqieImported': true},
    ];
    final result = await FanqieLibraryImportService().merge(
      FanqieImportPreview(records, 0, 0, 0),
    );
    return result.history;
  }

  Future<void> clearSession() => _account.invokeMethod<void>('clearSession');

  Future<void> cancelLogin() async {
    try {
      await _account.invokeMethod<void>('cancelLogin');
    } on PlatformException {
      // Cancellation still aborts Dart/Rust; closing a missing window is best effort.
    } on MissingPluginException {
      // Non-Android hosts have no native login window.
    }
  }
}
