import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'native_player.dart';

/// User-facing explanations only. Raw exceptions can contain signed video URLs
/// or backend response bodies and must never become the on-screen message.
enum PlaybackIssue {
  network('网络连接异常', '请检查 Wi-Fi 或移动网络，连接正常后重试。'),
  timeout('加载超时', '网络或视频响应较慢，请稍后重试。'),
  unavailable('视频暂时无法播放', '播放地址可能已失效，可以重试获取新地址，或切换其他剧集。'),
  service('播放服务暂时不可用', '请稍后重试，或先观看其他剧集。'),
  decoding('视频解析失败', '视频格式可能不受支持，可以重试或切换其他剧集。'),
  unknown('播放失败', '请重试，或切换其他剧集。'),
  empty('暂无可播放剧集', '返回后试试其他短剧。');

  final String title;
  final String message;

  const PlaybackIssue(this.title, this.message);

  static PlaybackIssue fromError(Object error) {
    if (error is TimeoutException) return timeout;
    if (error is NativePlaybackException) {
      final status = error.httpStatusCode;
      if (status != null) return _fromHttpStatus(status);
      // Media3 PlaybackException codes, retained by the native event bridge.
      return switch (error.errorCode ?? 0) {
        2001 => network, // IO_NETWORK_CONNECTION_FAILED
        2002 => timeout, // IO_NETWORK_CONNECTION_TIMEOUT
        2004 || 2005 => unavailable, // HTTP status / missing file
        2003 || >= 3001 && <= 3004 || >= 4001 && <= 4005 => decoding,
        _ => unknown,
      };
    }
    if (error is ApiException) {
      if (error.statusCode case final int status) {
        return _fromHttpStatus(status);
      }
      return error.message == '获取播放地址失败' ? unavailable : service;
    }
    if (error is http.ClientException) {
      // API calls use a local backend. A refused loopback connection says
      // nothing about whether Wi-Fi or mobile data is connected.
      final host = error.uri?.host;
      if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
        return service;
      }
      return network;
    }
    if (error is SocketException) return network;
    return unknown;
  }

  static PlaybackIssue _fromHttpStatus(int status) => switch (status) {
    408 || 504 => timeout,
    429 || >= 500 && <= 599 => service,
    401 || 403 || 404 || 410 || 416 => unavailable,
    _ => unknown,
  };
}
