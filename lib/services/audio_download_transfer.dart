import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'download_resume_store.dart';

const audioDownloadConnectTimeout = Duration(seconds: 10);
const audioDownloadReadTimeout = Duration(seconds: 20);

String audioDownloadFailureReason(Exception error) =>
    error is TimeoutException ? '下载超时' : error.toString();

bool isRetryableAudioDownloadFailure(String reason) {
  if (reason == '无效的章节或音色' ||
      reason == '取流结果与章节不匹配' ||
      reason == '该章没有可下载的音频地址' ||
      reason == '无效的剧集 ID' ||
      reason == '该集没有可下载的播放地址') {
    return false;
  }
  final match = RegExp(r'HTTP (\d{3})').firstMatch(reason);
  if (match == null) return true;
  final status = int.parse(match.group(1)!);
  return status == HttpStatus.requestTimeout ||
      status == HttpStatus.tooManyRequests ||
      status >= 500;
}

/// Promotes a completed part file and runs the caller's registration step.
///
/// Production ownership paths pass [deletePartOnConflict] false: a racing
/// final file must be reported without deleting the resumable part. The
/// default keeps the historical helper contract for callers that treat an
/// existing final as authoritative.
Future<bool> commitAudioDownload({
  required File partFile,
  required String finalPath,
  required bool Function() isAborted,
  required Future<void> Function() save,
  bool deletePartOnConflict = true,
}) async {
  if (isAborted()) return false;
  try {
    await partFile.rename(finalPath);
  } on FileSystemException {
    if (!deletePartOnConflict) rethrow;
    await partFile.delete();
  }
  if (isAborted()) return false;
  await save();
  return true;
}

enum DownloadRunStage { transferring, committing, cleaning }

class DownloadCancelled implements Exception {}

// Cancellation belongs to this run; resume must never clear it.
class DownloadRun {
  DownloadRun(this.key, this.generation);

  final DownloadKey key;
  final int generation;
  final Completer<void> _terminal = Completer<void>();
  Future<void> get terminal => _terminal.future;
  bool get settled => _terminal.isCompleted;
  DownloadRunStage stage = DownloadRunStage.transferring;
  String? _cancelled;
  bool discardRequested = false;
  bool rangeRejected = false;
  Object? cleanupError;
  DownloadFiles? files;
  DownloadResumeEntry? entry;
  HttpClient? client;
  RandomAccessFile? sink;
  RandomAccessFile? prefixReader;
  bool ownsFinal = false;

  bool pause() {
    if (stage == DownloadRunStage.committing) return false;
    _cancelled ??= 'paused';
    closeClient();
    return true;
  }

  void discard() {
    discardRequested = true;
    if (stage == DownloadRunStage.transferring) {
      _cancelled ??= 'discarded';
      closeClient();
    }
  }

  void check() {
    if (_cancelled != null) throw DownloadCancelled();
  }

  void closeClient() {
    final owned = client;
    client = null;
    owned?.close(force: true);
  }

  Future<void> closeIO() async {
    closeClient();
    final reader = prefixReader;
    if (reader != null) {
      await reader.close();
      prefixReader = null;
    }
    final owned = sink;
    if (owned != null) {
      await owned.close();
      sink = null;
    }
  }

  void settle() => _terminal.complete();
}

class DownloadSource {
  const DownloadSource({
    required this.uri,
    required this.containerId,
    required this.keyHex,
    this.rendition = '',
    this.height = 0,
  });

  final Uri uri;
  final String containerId;
  final String keyHex;
  final String rendition;
  final int height;

  DownloadIdentity identity(int total, Uri effective, String? tag) =>
      DownloadIdentity(
        containerId: containerId,
        keyHex: keyHex,
        rendition: rendition,
        height: height,
        total: total,
        requestedDigest: DownloadIdentity.uriDigest(uri),
        effectiveDigest: DownloadIdentity.uriDigest(effective),
        strongETag: tag,
      );
}

class DownloadTransferFailure implements Exception {
  const DownloadTransferFailure(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);
  final int start;
  final int end;
  final int total;

  static _ContentRange? parse(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(header.trim());
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        total == null ||
        start < 0 ||
        end < start ||
        total <= end) {
      return null;
    }
    return _ContentRange(start, end, total);
  }
}

Future<int> transferDownload({
  required DownloadRun run,
  required DownloadResumeStore journal,
  required DownloadSource source,
  required DownloadRecord record,
  required HttpClient Function() clientFactory,
  required Duration connectTimeout,
  required Duration readTimeout,
  required void Function(int received, int total) progress,
}) async {
  final files = run.files!;
  run.check();
  if (source.containerId.isEmpty ||
      source.height < 0 ||
      !RegExp(r'^(?:[0-9a-fA-F]{32})?$').hasMatch(source.keyHex) ||
      DownloadRecord.fromMap(record.toMap()) == null) {
    throw const DownloadTransferFailure('下载来源或记录无效');
  }
  final oldLength = await files.length(files.part) ?? 0;
  run.check();
  final old = run.entry?.identity;
  final verified =
      old != null &&
      old.containerId == source.containerId &&
      old.keyHex == source.keyHex &&
      old.rendition == source.rendition &&
      old.height == source.height &&
      oldLength <= old.total;
  final scoped =
      verified &&
      oldLength > 0 &&
      oldLength < old.total &&
      old.strongETag != null &&
      old.requestedDigest == DownloadIdentity.uriDigest(source.uri);

  try {
    while (true) {
      run.check();
      final useRange = scoped && !run.rangeRejected;
      final client = clientFactory()
        ..connectionTimeout = connectTimeout
        ..autoUncompress = false;
      run.client = client;
      final request = await client
          .openUrl('GET', source.uri)
          .timeout(
            connectTimeout,
            onTimeout: () {
              run.closeClient();
              throw TimeoutException('connect');
            },
          );
      run.check();
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (useRange) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$oldLength-');
        request.headers.set(HttpHeaders.ifRangeHeader, old.strongETag!);
      }
      final response = await request.close().timeout(
        readTimeout,
        onTimeout: () {
          run.closeClient();
          throw TimeoutException('headers');
        },
      );
      run.check();
      if (response.statusCode == 403 || response.statusCode == 410) {
        throw const DownloadTransferFailure('stale-url');
      }
      var effective = source.uri;
      for (final redirect in response.redirects) {
        effective = effective.resolveUri(redirect.location);
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      final tagHeader = response.headers.value(HttpHeaders.etagHeader);
      final tag = DownloadIdentity.strongTag(tagHeader);
      final range = _ContentRange.parse(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      final validRange =
          useRange &&
          response.statusCode == 206 &&
          range != null &&
          range.start == oldLength &&
          range.total == old.total &&
          old.effectiveDigest == DownloadIdentity.uriDigest(effective) &&
          (tagHeader == null || tag == old.strongETag) &&
          (response.contentLength < 0 ||
              response.contentLength == range.end - range.start + 1) &&
          (encoding == null || encoding.toLowerCase() == 'identity');
      if (useRange &&
          ((response.statusCode == 206 && !validRange) ||
              response.statusCode == 416)) {
        run.rangeRejected = true;
        run.closeClient();
        continue;
      }
      if (response.statusCode != 200 && !validRange) {
        throw DownloadTransferFailure('下载失败（HTTP ${response.statusCode}）');
      }
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw const DownloadTransferFailure('下载响应编码无效');
      }
      final total = validRange ? range.total : response.contentLength;
      if (total <= 0) throw const DownloadTransferFailure('服务器未提供有效的文件总长度');
      final allowance = validRange ? range.end - range.start + 1 : total;
      final identity = source.identity(
        total,
        effective,
        validRange ? (tag ?? old.strongETag) : tag,
      );
      final nextEntry = DownloadResumeEntry(
        run.key,
        DownloadResumeStage.receiving,
        identity: identity,
        record: record,
      );
      var prefix = !validRange && verified ? math.min(oldLength, total) : 0;
      var received = validRange ? oldLength : 0;
      var compared = 0;
      var responseReceived = 0;
      var installed = false;

      run.sink = await files.part.open(mode: FileMode.append);
      run.check();
      if (prefix > 0) {
        run.prefixReader = await files.part.open(mode: FileMode.read);
        run.check();
      }
      Future<void> install(int retained) async {
        run.check();
        if (!validRange) {
          await run.sink!.truncate(retained);
          run.check();
        }
        await run.sink!.setPosition(retained);
        run.check();
        await journal.write(nextEntry);
        // Track submitted journal work even if pause landed during its await.
        run.entry = nextEntry;
        run.check();
        installed = true;
        received = retained;
      }

      if (validRange || prefix == 0) await install(validRange ? oldLength : 0);
      progress(received, total);
      var sincePublish = 0;
      await for (final chunk in response.timeout(readTimeout)) {
        run.check();
        if (chunk.length > allowance - responseReceived) {
          throw const DownloadTransferFailure('下载响应超过声明长度');
        }
        responseReceived += chunk.length;
        sincePublish += chunk.length;
        var appendFrom = 0;
        if (!installed) {
          final compareCount = math.min(chunk.length, prefix - compared);
          final previous = await run.prefixReader!.read(compareCount);
          run.check();
          if (previous.length != compareCount) {
            throw const DownloadTransferFailure('下载半成品在校验期间发生变化');
          }
          var equal = 0;
          while (equal < compareCount && previous[equal] == chunk[equal]) {
            equal++;
          }
          compared += equal;
          appendFrom = equal;
          if (equal < compareCount || compared == prefix) {
            await run.prefixReader!.close();
            run.prefixReader = null;
            run.check();
            await install(compared);
            prefix = compared;
          } else {
            if (sincePublish >= 256 * 1024) {
              sincePublish = 0;
              progress(compared, total);
            }
            continue;
          }
        }
        final append = chunk.length - appendFrom;
        if (append > total - received) {
          throw const DownloadTransferFailure('下载文件超过声明总长度');
        }
        if (append > 0) {
          await run.sink!.writeFrom(chunk, appendFrom);
          run.check();
          received += append;
        }
        if (sincePublish >= 256 * 1024) {
          sincePublish = 0;
          progress(received, total);
        }
      }
      run.check();
      if (responseReceived != allowance || !installed || received != total) {
        throw const DownloadTransferFailure('下载不完整');
      }
      await run.sink!.flush();
      run.check();
      await run.closeIO();
      run.check();
      if (await files.length(files.part) != total) {
        throw const DownloadTransferFailure('下载文件长度发生变化');
      }
      run.check();
      progress(received, total);
      return total;
    }
  } finally {
    try {
      await run.closeIO();
    } catch (error) {
      run.cleanupError = error;
      rethrow;
    }
  }
}
