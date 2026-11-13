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

  test('注册连接失败显示精确域名和可操作指引，不要求关闭代理', () {
    final message = userFacingError(
      const ApiException(
        'get device: device_register: Network(dns error)',
        statusCode: 500,
      ),
    );
    expect(message, contains('log.snssdk.com:443'));
    expect(message, contains('拦截规则'));
    expect(message, contains('无需关闭代理'));
    expect(message, isNot(contains('dns error')));
  });

  test('非网络设备池错误不误报为代理或域名拦截', () {
    for (final error in [
      'get device: storage unavailable',
      'get device: device_register: HTTP 503',
      'get device: device_register: missing device_id',
    ]) {
      final message = userFacingError(ApiException(error, statusCode: 500));
      expect(message, isNot(contains('log.snssdk.com')));
      expect(message, isNot(contains('VPN')));
      expect(message, isNot(contains('拦截')));
    }
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
