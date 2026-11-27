import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/downloads/downloads_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/hourly_offline_cache.dart';
import 'package:workmanager/workmanager.dart';

import 'offline_cache_catchup_test.dart' as fixture;

class RecordingScheduler extends WorkmanagerPlatform {
  String? uniqueName;
  Duration? frequency;
  Constraints? constraints;
  ExistingPeriodicWorkPolicy? policy;
  String? cancelled;

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    this.uniqueName = uniqueName;
    this.frequency = frequency;
    this.constraints = constraints;
    policy = existingWorkPolicy;
    expect(taskName, hourlyOfflineCacheTask);
    expect(inputData, isNull);
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled = uniqueName;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      DBKeys.serverUrl.name: 'https://server.test',
      DBKeys.serverPortToggle.name: false,
    });
    OperationLog.instance.clear();
  });

  Future<fixture.CacheHarness> harness(
      FutureOr<Response> Function(Request request) response) async {
    final preferences = await SharedPreferences.getInstance();
    return fixture.CacheHarness(response, overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      graphQlClientProvider.overrideWith((ref) => GraphQLClient(
          cache: GraphQLCache(),
          link: Link.function((_, [__]) => const Stream.empty()))),
    ]);
  }

  test('registers unique hourly Wi-Fi work without requiring charging',
      () async {
    // Construct before installing the fake: Workmanager selects its host
    // implementation on first use (Linux in CI, unlike Windows locally).
    final workmanager = Workmanager();
    final previous = WorkmanagerPlatform.instance;
    final scheduler = RecordingScheduler();
    WorkmanagerPlatform.instance = scheduler;
    addTearDown(() => WorkmanagerPlatform.instance = previous);
    await scheduleHourlyOfflineCache(true, scheduler: workmanager);
    expect(scheduler.uniqueName, hourlyOfflineCacheTask);
    expect(scheduler.frequency, const Duration(hours: 1));
    expect(scheduler.policy, ExistingPeriodicWorkPolicy.keep);
    expect(scheduler.constraints?.networkType, NetworkType.unmetered);
    expect(scheduler.constraints?.requiresBatteryNotLow, isTrue);
    expect(scheduler.constraints?.requiresStorageNotLow, isTrue);
    expect(scheduler.constraints?.requiresCharging, isNot(true));
    await scheduleHourlyOfflineCache(false, scheduler: workmanager);
    expect(scheduler.cancelled, hourlyOfflineCacheTask);
  });

  test('headless worker copies a missed server download without foreground UI',
      () async {
    final cache =
        await harness((_) => fixture.candidatePage([fixture.candidate(4992)]));
    addTearDown(cache.dispose);

    expect(await runHourlyOfflineCache(cache.container), isTrue);
    expect(cache.manager.copies, [4992]);
    expect(cache.requests.single.operation.operationName,
        'GetOfflineCacheCandidates');
  });

  test(
      'background runtime uses memory cache without foreground Hive or sockets',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final container = createBackgroundCacheContainer(preferences);
    addTearDown(container.dispose);
    final client = container.read(graphQlClientProvider);
    expect(client.cache.store, isA<InMemoryStore>());
    final repository = container.read(downloadsRepositoryProvider);
    expect(repository.subscriptionClient, same(client));
    expect(
        container.read(mangaBookRepositoryProvider).cacheChapterPages, isFalse);
  });

  test('signed-out UI Login does not make server requests', () async {
    SharedPreferences.setMockInitialValues({
      DBKeys.serverUrl.name: 'https://server.test',
      DBKeys.authType.name: AuthType.uiLogin.index,
    });
    final cache = await harness((_) => throw StateError('must not fetch'));
    addTearDown(cache.dispose);
    expect(await runHourlyOfflineCache(cache.container), isTrue);
    expect(cache.requests, isEmpty);
  });

  test('metadata failure is retryable rather than a successful background run',
      () async {
    final cache = await harness((_) => throw StateError('private-url-secret'));
    addTearDown(cache.dispose);
    expect(await runHourlyOfflineCache(cache.container), isFalse);
    expect(OperationLog.instance.exportText(),
        isNot(contains('private-url-secret')));
  });

  test('background deadline returns retry and does not report completion',
      () async {
    final waiting = Completer<Response>();
    final cache = await harness((_) => waiting.future);
    addTearDown(cache.dispose);
    expect(
        await runHourlyOfflineCache(cache.container,
            budget: const Duration(milliseconds: 5)),
        isFalse);
    expect(OperationLog.instance.exportText(), contains('TimeoutException'));
    waiting.complete(fixture.candidatePage([]));
    await fixture.flushAsync();
  });

  test('background receipts retain actual time, copy counts and typed failure',
      () async {
    final preferences = await SharedPreferences.getInstance();
    OperationLog.instance.record('OfflineChapterCache',
        outcome: 'failed',
        error: StateError('private-server-token'),
        reasonCode: 'incomplete_page');
    OperationLog.instance.record('OfflineCacheCatchUp',
        outcome: 'scanned',
        count: 3,
        copied: 0,
        alreadyCached: 2,
        excluded: 0,
        failed: 1);
    OperationLog.instance.record('OfflineCacheHourly', outcome: 'failed');
    await saveHourlyCacheDiagnostics(preferences, false);
    OperationLog.instance.clear();
    await reportHourlyOfflineCache(preferences);
    final receipt = OperationLog.instance.latestEvent('OfflineCacheHourly')!;
    expect(receipt['copied'], 0);
    expect(receipt['alreadyCached'], 2);
    expect(receipt['failed'], 1);
    expect(receipt['errorType'], 'StateError');
    expect(receipt['reasonCode'], 'incomplete_page');
    expect(receipt['occurredAt'], isNotNull);
    expect(OperationLog.instance.exportJson(),
        isNot(contains('private-server-token')));
  });

  test('signed-out background receipt is skipped rather than copied', () async {
    final preferences = await SharedPreferences.getInstance();
    OperationLog.instance.record('OfflineCacheHourly', outcome: 'unconfigured');
    await saveHourlyCacheDiagnostics(preferences, true);
    OperationLog.instance.clear();
    await reportHourlyOfflineCache(preferences);
    final receipt = OperationLog.instance.latestEvent('OfflineCacheHourly')!;
    expect(receipt['outcome'], 'previous_run_skipped');
    expect(receipt['reasonCode'], 'not_configured');
    expect(receipt.containsKey('copied'), isFalse);
  });

  test('invalid background receipt is not reported as legacy success',
      () async {
    SharedPreferences.setMockInitialValues({
      'offlineCacheBackgroundLastRun': 123,
      'offlineCacheBackgroundOutcome': 'previous_run_completed',
      'offlineCacheBackgroundDiagnostic':
          '{"outcome":"previous_run_completed"}',
    });
    final preferences = await SharedPreferences.getInstance();
    await reportHourlyOfflineCache(preferences);
    final receipt = OperationLog.instance.latestEvent('OfflineCacheHourly')!;
    expect(receipt['outcome'], 'diagnostics_failed');
    expect(receipt['errorType'], 'FormatException');
    expect(receipt['reasonCode'], 'background_diagnostics_read_failed');
  });
}
