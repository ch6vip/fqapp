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
}
