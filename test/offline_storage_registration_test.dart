import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('storage capacity plugin registers for every Flutter engine', () {
    final dependency = File('pubspec.yaml').readAsStringSync();
    final plugin =
        File('packages/offline_storage/pubspec.yaml').readAsStringSync();
    expect(dependency, contains('path: packages/offline_storage'));
    expect(plugin, contains('pluginClass: OfflineStoragePlugin'));
    expect(plugin, contains('package: com.suwayomi.offline_storage'));
    final activity = File(
      'android/app/src/main/kotlin/com/suwayomi/tachidesk_sorayomi/MainActivity.kt',
    ).readAsStringSync();
    expect(activity, isNot(contains('OfflineStoragePlugin')));
    final implementation = File(
      'packages/offline_storage/android/src/main/kotlin/com/suwayomi/'
      'offline_storage/OfflineStoragePlugin.kt',
    ).readAsStringSync();
    expect(implementation, contains('FlutterPlugin'));
    expect(implementation, contains('binding.applicationContext'));
    expect(implementation, contains('StatFs(directory.path).availableBytes'));
    expect(implementation, contains('"storage_unavailable"'));
  });
}
