import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tachidesk_sorayomi/src/features/settings/data/local_cache_repository.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/general/cache_recovery_section.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/mutation_cache.dart';

class FakeCacheRepository extends LocalCacheRepository {
  FakeCacheRepository()
      : super(
          GraphQLClient(
            link: Link.function((request, [forward]) async* {}),
            cache: GraphQLCache(),
          ),
          MutationCache.forDirectory(Directory('unused-test-cache')),
        );

  var cleared = 0;
  int? forgotten;
  var fail = false;

  @override
  Future<int> clearLocalCache() async {
    if (fail) throw StateError('Local storage unavailable');
    cleared++;
    return 1;
  }

  @override
  Future<int> forgetManga(int mangaId) async {
    forgotten = mangaId;
    return 1;
  }

  @override
  Future<int> removeMissingMangaLinks() async => 0;
}

class FakeLogPicker extends FilePicker {
  Uint8List? savedBytes;
  bool cancelled = false;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    savedBytes = bytes;
    return cancelled ? null : 'operation-log.txt';
  }
}

Widget app(Widget child, {FakeCacheRepository? repository}) => ProviderScope(
      overrides: [
        if (repository != null)
          localCacheRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

Future<void> openConfirmation(WidgetTester tester, Finder button) async {
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => FilePicker.platform = FakeLogPicker());

  testWidgets('local cache buttons require confirmation and honor cancel',
      (tester) async {
    final repository = FakeCacheRepository();
    await tester
        .pumpWidget(app(const LocalCacheActions(), repository: repository));
    await openConfirmation(tester, find.text('Clear Cache'));
    expect(repository.cleared, 0);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Server data, sign-in settings'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(repository.cleared, 0);
    await openConfirmation(tester, find.text('Clear Cache'));
    await tester.tap(find.widgetWithText(TextButton, 'Clear Cache'));
    await tester.pumpAndSettle();
    expect(repository.cleared, 1);
    expect(find.text('Cache Cleared'), findsOneWidget);
  });

  testWidgets('cache storage failure is visible, not reported as success',
      (tester) async {
    final repository = FakeCacheRepository()..fail = true;
    await tester
        .pumpWidget(app(const LocalCacheActions(), repository: repository));
    await openConfirmation(tester, find.text('Clear Cache'));
    await tester.tap(find.widgetWithText(TextButton, 'Clear Cache'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Local storage unavailable'), findsOneWidget);
    expect(find.text('Cache Cleared'), findsNothing);
  });

  testWidgets('a manga can be forgotten even without a loaded manga model',
      (tester) async {
    final repository = FakeCacheRepository();
    await tester.pumpWidget(app(
      const LocalCacheActions(mangaId: 37),
      repository: repository,
    ));
    await openConfirmation(tester, find.byTooltip('Forget local manga'));
    await tester.tap(find.widgetWithText(TextButton, 'Forget local manga'));
    await tester.pumpAndSettle();
    expect(repository.forgotten, 37);
    expect(find.text('Local manga reference removed.'), findsOneWidget);
  });

  testWidgets('operation logs can be viewed, exported and explicitly cleared',
      (tester) async {
    final log = OperationLog();
    addTearDown(log.dispose);
    log.record('GetManga', outcome: 'graphql_error', id: 37, errorCount: 1);
    final originalPicker = FilePicker.platform;
    final picker = FakeLogPicker();
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = originalPicker);
    await tester.pumpWidget(app(OperationLogTile(operationLog: log)));
    await tester.tap(find.text('Operation log'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GetManga'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Export operation log'));
    await tester.pumpAndSettle();
    expect(picker.savedBytes, isNotNull);
    expect(utf8.decode(picker.savedBytes!), contains('id=37'));
    expect(find.text('Operation log saved.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Clear operation log'));
    await tester.pumpAndSettle();
    expect(log.value, isNotEmpty);
    await tester
        .tap(find.widgetWithText(TextButton, 'Clear operation log').last);
    await tester.pumpAndSettle();
    expect(log.value, isEmpty);
    expect(find.text('No operations logged yet.'), findsOneWidget);
  });

  testWidgets('cancelled log exports do not report a saved file',
      (tester) async {
    final log = OperationLog();
    addTearDown(log.dispose);
    log.record('Login', outcome: 'http_error', httpStatus: 401);
    final originalPicker = FilePicker.platform;
    FilePicker.platform = FakeLogPicker()..cancelled = true;
    addTearDown(() => FilePicker.platform = originalPicker);
    await tester.pumpWidget(app(OperationLogTile(operationLog: log)));
    await tester.tap(find.text('Operation log'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Export operation log'));
    await tester.pumpAndSettle();
    expect(find.text('Operation log saved.'), findsNothing);
    expect(log.value, hasLength(1));
  });
}
