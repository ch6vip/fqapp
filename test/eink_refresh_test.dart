import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/eink_refresh.dart';

void main() {
  test('无厂商接口时 requestRefresh 走软件白闪', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final service = EinkRefreshService.instance;
    final before = service.flashRequest.value;
    // flutter test 里没有原生通道，supported 为 false。
    expect(await service.supported, isFalse);
    await service.requestRefresh();
    expect(service.flashRequest.value, before + 1);
  });

  test('无厂商接口时 refreshIfSupported 不触发软件白闪', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final service = EinkRefreshService.instance;
    final before = service.flashRequest.value;
    expect(await service.supported, isFalse);
    // 弹窗关闭这类不改变正文的场景只用厂商接口，不能把正文盖白（#172）。
    expect(await service.refreshIfSupported(), isFalse);
    expect(service.flashRequest.value, before);
  });
}
