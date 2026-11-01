import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/assets.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/urls.dart';
import 'package:tachidesk_sorayomi/src/features/quick_open/presentation/search_stack/search_stack_screen.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/reader_settings_screen.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_ignore_safe_area_tile/reader_ignore_safe_area_tile.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_pinch_to_zoom/reader_pinch_to_zoom.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_smart_download_tile/reader_smart_download_tile.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_volume_tap_tile/reader_volume_tap_tile.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/utils/extensions/custom_extensions.dart';
import 'package:tachidesk_sorayomi/src/utils/misc/file_picker_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only Android application targets and packaging are maintained', () {
    for (final target in [
      'ios',
      'linux',
      'macos',
      'web',
      'windows',
      'scripts'
    ]) {
      expect(Directory(target).existsSync(), isFalse, reason: target);
    }
    final metadata = File('.metadata').readAsStringSync();
    final platforms = RegExp(r'platform: (\w+)')
        .allMatches(metadata)
        .map((match) => match[1])
        .toList();
    expect(platforms, ['root', 'android']);
    final workflow =
        File(p.join('.github', 'workflows', 'publish.yml')).readAsStringSync();
    expect(workflow, contains('flutter build apk --release'));
    expect(workflow, contains('flutter build apk --split-per-abi --release'));
    for (final target in ['ios', 'linux', 'macos', 'web', 'windows']) {
      expect(workflow, isNot(contains('flutter build $target')));
    }
    expect(AppUrls.sorayomiLatestReleaseUrl.url,
        'https://github.com/devnagui/Suwayomi-Android/releases/latest');
  });

  test('native Android uploads use the selected file path', () async {
    final directory = await Directory.systemTemp.createTemp('android-upload-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(p.join(directory.path, 'backup.tachibk'));
    await file.writeAsBytes([1, 2, 3, 4]);
    final upload = await FilePickerUtils.convertToMultipartFile(
      PlatformFile(name: 'backup.tachibk', size: 4, path: file.path),
    );
    expect(upload.filename, 'backup.tachibk');
    expect(await upload.finalize().toBytes(), [1, 2, 3, 4]);
    await expectLater(
      FilePickerUtils.convertToMultipartFile(
        PlatformFile(name: 'missing.tachibk', size: 0),
      ),
      throwsArgumentError,
    );
  });

  test('Android connection defaults and saved settings are preserved',
      () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
    ]);
    addTearDown(container.dispose);
    expect(container.read(serverUrlProvider), DBKeys.serverUrl.initial);
    expect(container.read(serverPortToggleProvider), isTrue);
    container.read(serverUrlProvider.notifier).update('https://example.test');
    container.read(serverPortToggleProvider.notifier).update(false);
    expect(container.read(serverUrlProvider), 'https://example.test');
    expect(container.read(serverPortToggleProvider), isFalse);
  });

  test('the minimal Android asset paths resolve correctly', () async {
    expect((await rootBundle.load(AppAssets.darkIcon)).lengthInBytes,
        greaterThan(0));
    expect((await rootBundle.load(AppAssets.previousDone)).lengthInBytes,
        greaterThan(0));
    for (final asset in [
      'ios_sorayomi_icon.png',
      'sorayomi_icon.ico',
      'sorayomi_preview_icon.png'
    ]) {
      expect(File(p.join('assets', 'icons', 'launcher', asset)).existsSync(),
          isFalse);
    }
  });

  testWidgets('phone, tablet and expanded-tablet breakpoints remain available',
      (tester) async {
    for (final sample in [
      (400.0, 'phone'),
      (800.0, 'tablet'),
      (1300.0, 'expanded'),
    ]) {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(sample.$1, 800)),
          child: Builder(
              builder: (context) => Text(context.responsiveValue(
                    mobile: 'phone',
                    tablet: 'tablet',
                    expandedTablet: 'expanded',
                  ))),
        ),
      ));
      expect(find.text(sample.$2), findsOneWidget);
    }
  });

  testWidgets(
      'Android pinch, offline caching and volume settings remain exposed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ReaderSettingsScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    for (final type in [
      ReaderPinchToZoom,
      ReaderSmartDownloadTile,
      ReaderIgnoreSafeAreaTile,
      ReaderVolumeTapTile,
    ]) {
      await tester.scrollUntilVisible(find.byType(type), 250);
      expect(find.byType(type), findsOneWidget);
    }
  });

  testWidgets('Android external keyboards retain Ctrl-P quick search',
      (tester) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    await tester.pumpWidget(MaterialApp(
      home: QuickSearchShortcutWrapper(
        visible: visible,
        child: const Focus(autofocus: true, child: SizedBox()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(visible.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(visible.value, isFalse);
  });
}
