import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerPortedUiLicenses() {
  LicenseRegistry.addLicense(() async* {
    // Retain both texts: the upstream NOTICE names its root LICENSE (v2)
    // and the separately bundled GPL-3.0.txt, without choosing one for it.
    for (final asset in ['PORTING.md', 'NOTICE', 'LICENSE', 'GPL-3.0.txt']) {
      yield LicenseEntryWithLineBreaks(const [
        'Wenku8 Flutter UI',
      ], await rootBundle.loadString('assets/licenses/wenku8/$asset'));
    }
  });
}
