import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/downloads/downloads_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads/downloads_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads_queue/downloads_queue_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_http_client.dart';
import 'package:tachidesk_sorayomi/src/utils/network/local_download_queue.dart';
import 'package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart';

import 'offline_cache_catchup_test.dart'
    show CacheHarness, candidate, candidatePage, finishedUpdate, flushAsync;

DownloadDto download({
  String state = 'ERROR',
  int tries = 3,
  double progress = 0,
}) =>
    DownloadDto.fromJson({
      ...finishedUpdate(4991).updates.single.download.toJson(),
      'state': state,
      'tries': tries,
      'progress': progress,
    });

DownloadStatusDto snapshot(DownloadDto value) => DownloadStatusDto(
      state: DownloaderState.STOPPED,
      queue: [value],
    );

DownloadUpdatesDto subscription(DownloadDto value,
        {DownloadUpdateType? event}) =>
    DownloadUpdatesDto(
      state: DownloaderState.STOPPED,
      initial: event == null ? [value] : null,
      updates: event == null
          ? const []
          : [DownloadUpdateDto(type: event, download: value)],
      omittedUpdates: false,
    );

List<Map<String, dynamic>> events([OperationLog? log]) =>
    ((jsonDecode((log ?? OperationLog.instance).exportJson())
            as Map<String, dynamic>)['events'] as List)
        .cast<Map<String, dynamic>>();

class DiagnosticDownloadsRepository extends DownloadsRepository {
  DiagnosticDownloadsRepository(GraphQLClient client, this.updates, this.status)
      : super(client, client);

  final Stream<DownloadUpdatesDto?> updates;
  final DownloadStatusDto status;
  int httpRequests = 0;

  @override
  Stream<DownloadUpdatesDto?> downloadStatusSubscription() => updates;

  @override
  Future<DownloadStatusDto?> getDownloadStatus() async {
    httpRequests++;
    return status;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => OperationLog.instance.clear());

  test('ERROR initial/snapshot/update coalesce, preserving attempts and unknown cause',
      () {
    final log = OperationLog();
    final diagnostics = ServerDownloadDiagnostics(log: log);
    final failed = download();
    diagnostics.snapshot(snapshot(failed));
    diagnostics.subscription(subscription(failed));
    diagnostics.subscription(
        subscription(failed, event: DownloadUpdateType.ERROR));
    diagnostics.snapshot(snapshot(failed));

    final event = events(log).single;
    expect(event['stage'], 'server_download');
    expect(event['outcome'], 'failed');
    expect(event['state'], 'ERROR');
    expect(event['attempt'], 3);
    expect(event['progressPercent'], 0);
    expect(event['mangaId'], 197);
    expect(event['chapterId'], 4991);
    expect(event['reasonCode'], 'server_reason_unavailable');
    expect(event.containsKey('exception'), isFalse);
    expect(event.containsKey('httpStatus'), isFalse);

    diagnostics.subscription(
        subscription(download(tries: 4), event: DownloadUpdateType.ERROR));
    expect(events(log), hasLength(2));
    expect(events(log).last['attempt'], 4);
  });

  test('state and terminal events retained without snapshot or fine progress spam',
      () {
    final log = OperationLog();
    final diagnostics = ServerDownloadDiagnostics(log: log);
    for (final progress in [0.0, 0.01, 0.10, 0.24, 0.26, 0.27, 0.25]) {
      final value =
          download(state: 'DOWNLOADING', tries: 1, progress: progress);
      diagnostics.subscription(
          subscription(value, event: DownloadUpdateType.PROGRESS));
      diagnostics.snapshot(snapshot(value));
    }
    expect(events(log), hasLength(2));
    final finished = download(state: 'FINISHED', progress: 1);
    diagnostics.subscription(
        subscription(finished, event: DownloadUpdateType.FINISHED));
    diagnostics.snapshot(snapshot(finished));
    diagnostics.subscription(
        subscription(finished, event: DownloadUpdateType.DEQUEUED));
    diagnostics.subscription(
        subscription(finished, event: DownloadUpdateType.DEQUEUED));
    expect(events(log).map((event) => event['state']),
        ['DOWNLOADING', 'DOWNLOADING', 'FINISHED', 'DEQUEUED']);
    expect(events(log).map((event) => event['outcome']),
        ['observed', 'observed', 'completed', 'dequeued']);
  });

  test('root subscription and HTTP provider share tracker without queue screen',
      () async {
    final stream = StreamController<DownloadUpdatesDto?>();
    addTearDown(stream.close);
    final client = GraphQLClient(
        cache: GraphQLCache(), link: Link.function((_, [__]) => const Stream.empty()));
    final repository =
        DiagnosticDownloadsRepository(client, stream.stream, snapshot(download()));
    final container = ProviderContainer(overrides: [
      downloadsRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    container.listen(downloadUpdatesProvider, (_, __) {});
    await flushAsync();
    stream.add(subscription(download()));
    await flushAsync();
    expect(events().single['reasonCode'], 'server_reason_unavailable');
    await container.read(downloadStatusProvider.future);
    expect(repository.httpRequests, 1);
    expect(events(), hasLength(1));
    stream.add(subscription(download(state: 'FINISHED', progress: 1),
        event: DownloadUpdateType.FINISHED));
    await flushAsync();
    expect(events().last['outcome'], 'completed');
  });

  testWidgets('existing fallback reports failed snapshots and coalesces polls',
      (tester) async {
    final stream = StreamController<DownloadUpdatesDto?>();
    final client = GraphQLClient(
        cache: GraphQLCache(), link: Link.function((_, [__]) => const Stream.empty()));
    final repository =
        DiagnosticDownloadsRepository(client, stream.stream, snapshot(download()));
    final container = ProviderContainer(overrides: [
      downloadsRepositoryProvider.overrideWithValue(repository),
    ]);
    container.listen(downloadStatusFallbackProvider, (_, __) {});
    await tester.pump();
    stream.addError(StateError('subscription unavailable'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(repository.httpRequests, 1);
    expect(events().single['reasonCode'], 'server_reason_unavailable');
    await tester.pump(const Duration(seconds: 5));
    expect(repository.httpRequests, 2);
    expect(events(), hasLength(1));
    container.dispose();
    unawaited(stream.close());
    await tester.pump();
  });

  test('catch-up distinguishes candidates, copies, already cached and exclusions',
      () async {
    final harness = CacheHarness(
        (_) => candidatePage([candidate(1), candidate(2), candidate(3)]),
        available: {1});
    addTearDown(harness.dispose);
    await harness.queue.cancel(3);
    expect(await harness.queue.reconcile(), isTrue);
    final summary =
        events().lastWhere((event) => event['operation'] == 'OfflineCacheCatchUp');
    expect(summary['stage'], 'device_cache');
    expect(summary['count'], 3);
    expect(summary['copied'], 1);
    expect(summary['alreadyCached'], 1);
    expect(summary['excluded'], 1);
    expect(summary['failed'], 0);
    expect(harness.manager.copies, [2]);
    final chapterEvents =
        events().where((event) => event['operation'] == 'OfflineChapterCache');
    expect(chapterEvents.map((event) => event['outcome']),
        containsAll(['already_on_device', 'queued', 'started', 'completed', 'excluded']));
    await harness.queue.reconcile();
    final noOp = events().last;
    expect(noOp['copied'], 0);
    expect(noOp['alreadyCached'], 2);
    expect(noOp['excluded'], 1);
    expect(noOp['failed'], 0);
  });

  test('catch-up waits for a concurrent reserved chapter disk check', () async {
    final harness = CacheHarness((_) => candidatePage([candidate(1)]));
    addTearDown(harness.dispose);
    final gate = Completer<void>();
    harness.manager.checkGate = gate;
    final arrival = harness.queue.enqueue(197, 1);
    await flushAsync();
    var finished = false;
    final scan = harness.queue.reconcile().then((result) {
      finished = true;
      return result;
    });
    await flushAsync();
    expect(finished, isFalse);
    gate.complete();
    await arrival;
    expect(await scan, isTrue);
    expect(events().last['copied'], 1);
    expect(events().last['failed'], 0);
    expect(harness.manager.copies, [1]);
  });

  test('catch-up result ignores failures absent from the current candidates',
      () async {
    var chapters = [candidate(1)];
    final harness = CacheHarness((_) => candidatePage(chapters));
    addTearDown(harness.dispose);
    harness.manager.failChecks = true;
    expect(await harness.queue.reconcile(), isFalse);
    expect(harness.container.read(localDownloadQueueProvider)[1]?.status,
        LocalCacheStatus.failed);

    harness.manager.failChecks = false;
    chapters = [candidate(2)];
    expect(await harness.queue.reconcile(), isTrue);
    expect(harness.container.read(localDownloadQueueProvider)[1]?.status,
        LocalCacheStatus.failed);
    final summary = events().last;
    expect(summary['operation'], 'OfflineCacheCatchUp');
    expect(summary['outcome'], 'completed');
    expect(summary['count'], 1);
    expect(summary['copied'], 1);
    expect(summary['failed'], 0);
  });


  group('local failures', () {
    late Directory directory;
    late SharedPreferences preferences;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('download-diagnostics-');
      SharedPreferences.setMockInitialValues({
        DBKeys.serverUrl.name: 'http://server.test',
        DBKeys.serverPortToggle.name: false,
      });
      preferences = await SharedPreferences.getInstance();
    });
    tearDown(() async => directory.delete(recursive: true));

    CacheHarness harness(http.Client media,
            {Future<Directory> Function()? documentsDirectory}) {
      addTearDown(media.close);
      final result = CacheHarness(
          (_) => candidatePage([candidate(4991)]),
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            serverMediaHttpClientProvider.overrideWithValue(media),
            offlineChapterManagerProvider.overrideWith((ref) =>
                OfflineChapterManager(ref,
                    documentsDirectory:
                        documentsDirectory ?? () async => directory)),
          ]);
      addTearDown(result.dispose);
      return result;
    }

    test('actual network cause, app stack, page counts survive queue retries safely',
        () async {
      final cause = http.ClientException(
          'https://user:password@private.test/chapter?token=secret');
      final cache = harness(MockClient((_) async => Error.throwWithStackTrace(
          cause,
          StackTrace.fromString(
              '#0 cache (package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart:222:7)\n'
              '#1 private (https://user:password@private.test/?token=secret:1:2)\n'))));
      expect(await cache.queue.reconcile(), isFalse);
      final failures = events().where((event) =>
          event['operation'] == 'OfflineChapterCache' &&
          event['outcome'] == 'failed');
      expect(failures, hasLength(3));
      expect(failures.map((event) => event['attempt']), [1, 2, 3]);
      for (final event in failures) {
        expect(event['reasonCode'], 'network_error');
        expect(event['errorType'], 'ClientException');
        expect((event['exception'] as Map)['type'], 'ClientException');
        expect((event['exception'] as Map)['stack'],
            ['package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart:222:7']);
        expect(event['completedPages'], 0);
        expect(event['totalPages'], 1);
      }
      expect(events().where((event) => event['outcome'] == 'retry'), hasLength(2));
      expect(events().last['failed'], 1);
      expect(events().last['copied'], 0);
      for (final secret in ['password', 'private.test', 'token=secret']) {
        expect(OperationLog.instance.exportJson(), isNot(contains(secret)));
        expect(OperationLog.instance.exportText(), isNot(contains(secret)));
      }
    });

    test('manager carries actual disk exception without rendering its message',
        () async {
      final cause = FileSystemException('password=secret', 'D:/private-path');
      final cache = harness(MockClient((_) async => http.Response('', 200)),
          documentsDirectory: () async => throw cause);
      final manager = cache.container.read(offlineChapterManagerProvider);
      final progress = (await manager.downloadChapter(
          mangaId: 197, chapterId: 4991, pageUrls: ['/page']).toList()).single;
      expect(progress.cause, same(cause));
      expect(progress.stackTrace, isNotNull);
      expect(progress.reasonCode, 'disk_error');
      expect(progress.error, isNot(contains('secret')));
      await cache.queue.reconcile();
      final failure = events()
          .firstWhere((event) =>
              event['operation'] == 'OfflineChapterCache' &&
              event['outcome'] == 'failed');
      expect(failure['errorType'], 'FileSystemException');
      expect(failure['reasonCode'], 'disk_error');
      expect(OperationLog.instance.exportJson(), isNot(contains('private-path')));
    });

    for (final scenario in [
      (status: 503, body: <int>[1], reason: 'http_status'),
      (status: 200, body: <int>[], reason: 'empty_page'),
      (status: 200, body: <int>[1], reason: 'incomplete_page'),
    ]) {
      test('manager distinguishes ${scenario.reason} and preserves HTTP status',
          () async {
        final cache = harness(MockClient((_) async => http.Response.bytes(
            scenario.body, scenario.status,
            headers: {'content-length': '20'})));
        final progress = (await cache.container
                .read(offlineChapterManagerProvider)
                .downloadChapter(
                    mangaId: 197, chapterId: 4991, pageUrls: ['/page'])
                .toList())
            .last;
        expect(progress.reasonCode, scenario.reason);
        expect(progress.httpStatus, scenario.status);
        expect(progress.cause, isA<LocalCacheException>());
        expect(progress.isComplete, isFalse);
      });
    }

    test('manager distinguishes an empty chapter without inventing HTTP status',
        () async {
      final cache = harness(MockClient((_) async => http.Response('', 200)));
      final progress = (await cache.container
              .read(offlineChapterManagerProvider)
              .downloadChapter(
                  mangaId: 197, chapterId: 4991, pageUrls: const [])
              .toList())
          .single;
      expect(progress.reasonCode, 'empty_pages');
      expect(progress.httpStatus, isNull);
    });

    for (final clearAll in [false, true]) {
      test('in-flight ${clearAll ? 'clear' : 'exclusion'} keeps a distinct reason',
          () async {
        late OfflineChapterManager manager;
        final cache = harness(MockClient((_) async {
          if (clearAll) {
            await manager.clearAllOfflineData();
          } else {
            await manager.deleteOfflineChapter(197, 4991);
          }
          return http.Response.bytes([1, 2, 3], 200);
        }));
        manager = cache.container.read(offlineChapterManagerProvider);
        final progress = (await manager.downloadChapter(
            mangaId: 197, chapterId: 4991, pageUrls: ['/page']).toList()).last;
        expect(progress.reasonCode, clearAll ? 'cache_cleared' : 'cache_excluded');
        expect(progress.isComplete, isFalse);
        expect(await manager.isChapterAvailableOffline(197, 4991), isFalse);
      });
    }
  });
}
