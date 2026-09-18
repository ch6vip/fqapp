import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release builds disable cloud backup and device-to-device copies', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="@xml/backup_rules"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );

    final backup = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    expect(backup, contains('<full-backup-content>'));
    expect(backup, contains('<exclude domain="file" path="."'));

    final extraction = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();
    expect(
      extraction,
      matches(
        RegExp(
          r'<cloud-backup>[\s\S]*<exclude domain="file" path="\."[\s\S]*</cloud-backup>',
        ),
      ),
    );
    expect(
      extraction,
      matches(
        RegExp(
          r'<device-transfer>[\s\S]*<exclude domain="file" path="\."[\s\S]*</device-transfer>',
        ),
      ),
    );
  });
}
