import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';

final _hasCuratedText = RegExp(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]');

/// The message a content page (search, ranks, author, comic, home, detail)
/// shows when a load fails. Raw exceptions can carry signed URLs or backend
/// response bodies — the rule playback_issue.dart states for the player holds
/// everywhere: they must never become the on-screen text. A plain English
/// `TimeoutException after 0:00:20…` in a Chinese UI is the symptom.
// Note: 错误文案映射的取舍(CJK 才透传)与审查批次记录 — 见
// .agents/notes/implemented/bug-fix/2026-09-19-cross-review-batch-fixes.md
String userFacingError(Object error) {
  if (error is ApiException) {
    // The client's own exceptions carry curated Chinese messages ('正文为空',
    // '搜索失败'); a bare upstream code like `NO_THIS_TONE` is not user text.
    final message = error.message.trim();
    if (message.isNotEmpty && _hasCuratedText.hasMatch(message)) return message;
    return '加载失败，请稍后重试';
  }
  if (error is TimeoutException) return '加载超时，请检查网络后重试';
  if (error is SocketException || error is http.ClientException) {
    // API calls go through the local backend, so a refused loopback
    // connection says nothing about the device's actual connectivity.
    return '网络连接异常，请稍后重试';
  }
  if (error is FormatException) return '内容解析失败，请稍后重试';
  return '加载失败，请稍后重试';
}
