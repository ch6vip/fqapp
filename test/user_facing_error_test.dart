import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/user_facing_error.dart';

void main() {
  test('核心截止超时显示超时文案，而不是通用失败（issue #212）', () {
    expect(
      userFacingError(BackendRequestAborted('请求超时', timedOut: true)),
      '加载超时，请检查网络后重试',
    );
    expect(userFacingError(TimeoutException('late')), '加载超时，请检查网络后重试');
  });

  test('主动取消不算超时', () {
    expect(userFacingError(BackendRequestAborted('请求已取消')), '加载失败，请稍后重试');
  });

  test('设备池取设备失败提示检查网络，不透出英文原文（issue #212）', () {
    final message = userFacingError(
      const ApiException(
        'get device: device_register: Network(dns error)',
        statusCode: 500,
      ),
    );
    expect(message, '设备注册失败，请检查网络、VPN 或私人 DNS 后重试');
    expect(message, isNot(contains('dns error')));
  });

  test('其它英文核心错误仍用通用文案，中文消息原样透传', () {
    expect(
      userFacingError(
        const ApiException(
          'device request failed after 3 retries',
          statusCode: 500,
        ),
      ),
      '加载失败，请稍后重试',
    );
    expect(userFacingError(const ApiException('正文为空')), '正文为空');
  });
}
