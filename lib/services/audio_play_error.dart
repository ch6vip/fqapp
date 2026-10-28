import 'api_client.dart';

/// 听书播放失败时，官方给出的那两句「有原因」的提示。
///
/// 反编译取证：
/// * `ug` = 「本章该音色已下架」
/// * `uj` = 「本章正在审核中，请先看其他章节」
///
/// 上游只保证 `NO_THIS_TONE` 这个码；「审核中」的具体码没有取证到，因此这里
/// 按消息里的关键字识别，识别不到就返回 null，由调用方回落到通用文案——
/// 宁可给通用提示，也不要把裸错误码甩给用户。
String? audioPlayErrorMessage(Object error, {bool switchedTone = false}) {
  final message = error is ApiException ? error.message : error.toString();
  if (message.contains('NO_THIS_TONE')) {
    return switchedTone ? '本章该音色已下架，已为你换用其它音色' : '本章该音色已下架';
  }
  const reviewMarkers = <String>['审核', 'UNDER_REVIEW', 'AUDITING', 'REVIEWING'];
  for (final marker in reviewMarkers) {
    if (message.contains(marker)) return '本章正在审核中，请先看其他章节';
  }
  return null;
}
