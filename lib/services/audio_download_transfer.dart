import 'dart:async';
import 'dart:io';

/// 听书下载的传输阶段：期限、失败分类与落盘收尾。
///
/// `AudioDownloader` 负责任务队列与重试循环，这里放单次传输的公共规则，
/// 免得「等多久算失败」「哪种失败值得再试」「放弃和改名谁先谁后」散在
/// 循环里难以单测。

/// 建连与读的期限。
///
/// CDN 偶尔接受连接后不再吐数据：没有期限的等响应头/读正文会让下载协程
/// 永远挂着，`_active` 的槽位也一直不释放，后续任务全部排队。
const audioDownloadConnectTimeout = Duration(seconds: 10);
const audioDownloadReadTimeout = Duration(seconds: 20);

/// 异常 → 任务面板可读的失败原因。
///
/// 超时单独成句：它按可重试的网络故障处理（见
/// [isRetryableAudioDownloadFailure]），但直接甩 `TimeoutException` 的
/// 长串文本给用户没有意义。
String audioDownloadFailureReason(Exception error) =>
    error is TimeoutException ? '下载超时' : error.toString();

/// 这个失败原因值不值得再试一次。
///
/// 章节/音色不合法、取流结果对不上是永久错误；HTTP 4xx 里只有 408/429
/// 表示「稍后再试」，其余（404、空响应的 416 等）重试也是同一个结果。
/// 5xx、断流、超时、续传校验失败这类网络侧偶发问题才重试。
bool isRetryableAudioDownloadFailure(String reason) {
  if (reason == '无效的章节或音色' ||
      reason == '取流结果与章节不匹配' ||
      reason == '该章没有可下载的音频地址') {
    return false;
  }
  final match = RegExp(r'HTTP (\d{3})').firstMatch(reason);
  if (match == null) return true;
  final status = int.parse(match.group(1)!);
  return status == HttpStatus.requestTimeout ||
      status == HttpStatus.tooManyRequests ||
      status >= 500;
}

/// 把下载完成的 `.part` 改名成终稿，并在登记前再确认一次没有被放弃。
///
/// 改名是个 await 点：用户可能正好在这期间点了放弃。`discard` 只删
/// `.part`，改名成功后它什么也删不到；旧协程若接着 [save]，就把用户刚删掉
/// 的下载又写回了记录。返回 false 表示已放弃，调用方不得再登记。
Future<bool> commitAudioDownload({
  required File partFile,
  required String finalPath,
  required bool Function() isAborted,
  required Future<void> Function() save,
}) async {
  if (isAborted()) return false;
  try {
    await partFile.rename(finalPath);
  } on FileSystemException {
    // 同名终稿已存在（重复下载竞态）：以已存在文件为准。
    await partFile.delete();
  }
  if (isAborted()) return false;
  await save();
  return true;
}
