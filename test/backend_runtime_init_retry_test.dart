import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/backend_transport.dart';

/// The bridge runtime is a process-wide one-shot: a successful load is reused,
/// but a load that fails must not be cached, or the app could never start the
/// core again after one bad native init.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(RustBackendTransport.resetRuntimeForTest);

  test(
    'a failed bridge init is not cached and the next attempt runs again',
    () async {
      var attempts = 0;
      RustBackendTransport.runtimeInitializer = () async {
        attempts += 1;
        if (attempts == 1) {
          throw StateError('dlopen failed');
        }
      };

      await expectLater(RustBackendTransport.ensureRuntime(), throwsStateError);
      await RustBackendTransport.ensureRuntime();

      expect(attempts, 2);
    },
  );

  test('a successful bridge init stays cached for the process', () async {
    var attempts = 0;
    RustBackendTransport.runtimeInitializer = () async {
      attempts += 1;
    };

    await RustBackendTransport.ensureRuntime();
    await RustBackendTransport.ensureRuntime();

    expect(attempts, 1);
  });
}
