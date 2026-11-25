import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gql/language.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/downloads/downloads_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter_page/chapter_page_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads/downloads_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/widgets/download_status_icon.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/routes/router_config.dart';
import 'package:tachidesk_sorayomi/src/sorayomi.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/misc/toast/toast.dart';
import 'package:tachidesk_sorayomi/src/utils/network/connectivity_provider.dart';
import 'package:tachidesk_sorayomi/src/utils/network/local_download_queue.dart';
import 'package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart';
import 'package:tachidesk_sorayomi/src/utils/network/token_manager.dart';

Map<String, dynamic> candidate(int id,
        {bool downloaded = true, bool read = false, bool library = true}) =>
    {
      '__typename': 'ChapterType',
      'id': id,
      'mangaId': 197,
      'user': {
        '__typename': 'ChapterUserType',
        'isDownloaded': downloaded,
        'isRead': read,
      },
      'manga': {
        '__typename': 'MangaType',
        'user': {'__typename': 'MangaUserType', 'inLibrary': library},
      },
    };

Response candidatePage(List<Map<String, dynamic>> chapters,
        {bool hasNext = false, String? cursor}) =>
    Response(
      response: const {},
      data: {
        '__typename': 'Query',
        'chapters': {
          '__typename': 'ChapterNodeList',
          'nodes': chapters,
          'pageInfo': {
            '__typename': 'PageInfo',
            'hasNextPage': hasNext,
            'hasPreviousPage': false,
            'startCursor': null,
            'endCursor': cursor,
          },
        },
      },
    );

class MemoryOfflineManager extends OfflineChapterManager {
  MemoryOfflineManager(super.ref, this.available);

  final Set<int> available;
  final copies = <int>[];
  int active = 0;
  int maxActive = 0;
  Completer<void>? checkGate;
  Completer<void>? copyGate;
  bool failChecks = false;
  bool failCopies = false;

  @override
  Future<bool> isAutomaticallyExcluded(int mangaId, int chapterId) async => false;

  @override
  Future<void> allowAutomaticCache(int mangaId, int chapterId) async {}

  @override
  Future<bool> isChapterAvailableOffline(int mangaId, int chapterId) async {
    await checkGate?.future;
    if (failChecks) throw StateError('private-server-url-must-not-be-logged');
    return available.contains(chapterId);
  }

  @override
  Stream<LocalDownloadProgress> downloadChapter({
    required int mangaId,
    required int chapterId,
    required List<String> pageUrls,
    bool logDiagnostics = true,
  }) async* {
    copies.add(chapterId);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await copyGate?.future;
      if (failCopies) {
        yield LocalDownloadProgress(
          chapterId: chapterId,
          mangaId: mangaId,
          totalPages: 1,
          downloadedPages: 0,
          isComplete: false,
          error: 'HTTP 503',
        );
        return;
      }
      available.add(chapterId);
      yield LocalDownloadProgress(
        chapterId: chapterId,
        mangaId: mangaId,
        totalPages: 1,
        downloadedPages: 1,
        isComplete: true,
      );
    } finally {
      active--;
    }
  }
}

class CachedPagesRepository extends MangaBookRepository {
  CachedPagesRepository(super.client, super.ref);

  @override
  Future<ChapterPagesDto?> getChapterPages({required int chapterId}) async =>
      ChapterPagesDto.fromJson({
        '__typename': 'FetchChapterPagesPayload',
        'chapter': {
          '__typename': 'ChapterType',
          'id': chapterId,
          'pageCount': 1,
        },
        'pages': ['/api/v1/page/$chapterId/0'],
      });
}

class CacheHarness {
  CacheHarness(
    FutureOr<Response> Function(Request request) respond, {
    Set<int>? available,
    Stream<DownloadUpdatesDto?>? updates,
    List<Override> overrides = const [],
  }) {
    client = GraphQLClient(
      cache: GraphQLCache(),
      link: Link.function((request, [forward]) async* {
        requests.add(request);
        yield await respond(request);
      }),
    );
    container = ProviderContainer(overrides: [
      downloadsRepositoryProvider.overrideWith(
        (ref) => DownloadsRepository(client, client),
      ),
      downloadUpdatesProvider.overrideWith(
        (ref) => updates ?? const Stream.empty(),
      ),
      mangaBookRepositoryProvider.overrideWith(
        (ref) => CachedPagesRepository(client, ref),
      ),
      offlineChapterManagerProvider.overrideWith((ref) {
        manager = MemoryOfflineManager(ref, available ?? <int>{});
        return manager;
      }),
      ...overrides,
    ]);
    // The real manager is stateless; keep the recording test double alive
    // across asynchronous page boundaries.
    container.listen(offlineChapterManagerProvider, (_, __) {});
  }

  late final GraphQLClient client;
  late final ProviderContainer container;
  late MemoryOfflineManager manager;
  final requests = <Request>[];

  LocalDownloadQueue get queue =>
      container.read(localDownloadQueueProvider.notifier);

  void dispose() => container.dispose();
}

Future<void> flushAsync() => Future<void>.delayed(Duration.zero);

class ControlledConnectivity extends ConnectivityStatus {
  @override
  bool build() => true;

  void setOnline(bool online) => state = online;
}

DownloadUpdatesDto finishedUpdate(int chapterId) =>
    DownloadUpdatesDto.fromJson({
      '__typename': 'DownloadUpdates',
      'state': 'STOPPED',
      'initial': null,
      'omittedUpdates': false,
      'updates': [
        {
          '__typename': 'DownloadUpdate',
          'type': 'FINISHED',
          'download': {
            '__typename': 'DownloadType',
            'chapter': {
              '__typename': 'ChapterType',
              'id': chapterId,
              'name': 'Chapter',
              'sourceOrder': 286,
              'user': {
                '__typename': 'ChapterUserType',
                'isDownloaded': true,
              },
            },
            'manga': {
              '__typename': 'MangaType',
              'id': 197,
              'title': 'Manga',
              'thumbnailUrl': null,
              'user': {
                '__typename': 'MangaUserType',
                'downloadCount': 1,
              },
            },
            'progress': 1.0,
            'state': 'FINISHED',
            'tries': 0,
            'position': 0,
          },
        },
      ],
    });

void main() {
  setUp(() => OperationLog.instance.clear());

  test('startup catches missed FINISHED and restart preserves the local copy',
      () async {
    final disk = <int>{};
    final first = CacheHarness((_) => candidatePage([candidate(4985)]),
        available: disk);
    await first.queue.reconcile();
    expect(first.manager.copies, [4985]);
    expect(first.container.read(localDownloadQueueProvider)[4985]?.status,
        LocalCacheStatus.done);
    first.dispose();

    final restarted = CacheHarness((_) => candidatePage([candidate(4985)]),
        available: disk);
    addTearDown(restarted.dispose);
    await restarted.queue.reconcile();
    expect(restarted.manager.copies, isEmpty);
    expect(disk, {4985});
    expect(restarted.requests.single.operation.operationName,
        'GetOfflineCacheCandidates');
  });

  test('server query and returned flags exclude read/non-library/not-downloaded',
      () async {
    final harness = CacheHarness((request) {
      expect(request.variables['first'], 25);
      final query = printNode(request.operation.document);
      expect(query, contains('inLibrary: {equalTo: true}'));
      expect(query, contains('isDownloaded: {equalTo: true}'));
      expect(query, contains('isRead: {equalTo: false}'));
      return candidatePage([
        candidate(1),
        candidate(2, read: true),
        candidate(3, library: false),
        candidate(4, downloaded: false),
      ]);
    });
    addTearDown(harness.dispose);
    await harness.queue.reconcile();
    expect(harness.manager.copies, [1]);
  });

  test('concurrent enqueue reserves before disk check and copies only once',
      () async {
    final harness = CacheHarness((_) => candidatePage([]));
    addTearDown(harness.dispose);
    harness.container.read(offlineChapterManagerProvider);
    final gate = Completer<void>();
    harness.manager.checkGate = gate;

    final first = harness.queue.enqueue(197, 4985);
    final second = harness.queue.enqueue(197, 4985);
    gate.complete();
    await Future.wait([first, second]);
    await flushAsync();
    expect(harness.manager.copies, [4985]);
    expect(harness.manager.maxActive, 1);
  });

  test('enqueue at worker completion never strands queued chapters', () async {
    final harness = CacheHarness((_) => candidatePage([]));
    addTearDown(harness.dispose);
    final done = Completer<void>();
    Future<void>? arrival;
    var startedNext = false;
    harness.container.listen(localDownloadQueueProvider, (_, next) {
      if (next[1]?.status == LocalCacheStatus.done && !startedNext) {
        startedNext = true;
        // Its asynchronous disk check completes between the worker's final
        // empty check and its completion callback. No later enqueue may rescue
        // the successor if that callback forgets to restart queued work.
        arrival = harness.queue.enqueue(197, 2);
      }
      if (next[2]?.status == LocalCacheStatus.done && !done.isCompleted) {
        done.complete();
      }
    });
    await harness.queue.enqueue(197, 1);
    await done.future.timeout(const Duration(seconds: 2));
    await arrival;
    expect(harness.manager.copies, [1, 2]);
    expect(harness.manager.maxActive, 1);
  });

  test('catch-up pages opaque cursors only after serialized local work drains',
      () async {
    final harness = CacheHarness((request) {
      if (request.variables['after'] == null) {
        return candidatePage([candidate(1), candidate(2)],
            hasNext: true, cursor: 'opaque:next');
      }
      expect(request.variables['after'], 'opaque:next');
      return candidatePage([candidate(3)]);
    });
    addTearDown(harness.dispose);
    harness.container.read(offlineChapterManagerProvider);
    final gate = Completer<void>();
    harness.manager.copyGate = gate;
    final scan = harness.queue.reconcile();
    final duplicateScan = harness.queue.reconcile();
    await flushAsync();
    expect(harness.requests, hasLength(1));
    expect(harness.manager.copies, [1]);
    expect(harness.container.read(localDownloadQueueProvider), hasLength(1));
    gate.complete();
    await Future.wait([scan, duplicateScan]);
    expect(harness.manager.copies, [1, 2, 3]);
    expect(harness.manager.maxActive, 1);
    expect(harness.requests, hasLength(2));
  });

  test('foreground catches up again and background does not start a scan',
      () async {
    final harness = CacheHarness((_) => candidatePage([candidate(1)]));
    addTearDown(harness.dispose);
    harness.queue.setForeground(false);
    await harness.queue.reconcile();
    expect(harness.requests, isEmpty);
    harness.queue.setForeground(true);
    await harness.queue.reconcile();
    expect(harness.manager.copies, [1]);
  });

  test('reconnected subscription initial message reconciles without FINISHED',
      () async {
    final updates = StreamController<DownloadUpdatesDto?>();
    addTearDown(updates.close);
    final harness = CacheHarness((_) => candidatePage([candidate(4985)]),
        updates: updates.stream);
    addTearDown(harness.dispose);
    harness.queue;
    await flushAsync();
    updates.add(DownloadUpdatesDto(
      state: DownloaderState.STOPPED,
      initial: const [],
      updates: const [],
      omittedUpdates: false,
    ));
    await flushAsync();
    await harness.queue.reconcile();
    expect(harness.manager.copies, [4985]);
  });

  test('manual removal is not undone by stale catch-up metadata', () async {
    final harness = CacheHarness((_) => candidatePage([candidate(4985)]));
    addTearDown(harness.dispose);
    await harness.queue.cancel(4985);
    await harness.queue.reconcile();
    expect(harness.container.read(localDownloadQueueProvider), isEmpty);
    // Explicit saving may override the automatic-removal suppression.
    await harness.queue.enqueue(197, 4985);
    await flushAsync();
    expect(harness.manager.copies, [4985]);
  });

  test('late FINISHED respects removal; explicit saving opts back in',
      () async {
    final updates = StreamController<DownloadUpdatesDto?>();
    addTearDown(updates.close);
    final harness = CacheHarness((_) => candidatePage([]),
        updates: updates.stream);
    addTearDown(harness.dispose);
    await harness.queue.cancel(4985);
    await flushAsync();
    updates.add(finishedUpdate(4985));
    await flushAsync();
    expect(harness.manager.copies, isEmpty);
    expect(harness.container.read(localDownloadQueueProvider), isEmpty);

    await harness.queue.enqueue(197, 4985);
    await flushAsync();
    expect(harness.manager.copies, [4985]);
    expect(harness.requests, isEmpty);
  });

  test('manual removal waits for the active writer before deleting its copy',
      () async {
    final harness = CacheHarness((_) => candidatePage([candidate(4985)]));
    addTearDown(harness.dispose);
    final gate = Completer<void>();
    harness.manager.copyGate = gate;
    await harness.queue.enqueue(197, 4985);
    await flushAsync();
    var stopped = false;
    final cancellation = harness.queue.cancel(4985).then((_) => stopped = true);
    await flushAsync();
    expect(stopped, isFalse);
    gate.complete();
    await cancellation;
    expect(harness.manager.active, 0);
    harness.manager.available.remove(4985); // Manual file deletion.
    await harness.queue.reconcile();
    expect(harness.manager.copies, [4985]);
    expect(harness.manager.available, isEmpty);
    expect(harness.container.read(localDownloadQueueProvider), isEmpty);
  });

  test('page failures finish as failed after bounded retries', () async {
    final harness = CacheHarness((_) => candidatePage([candidate(4985)]));
    addTearDown(harness.dispose);
    harness.manager.failCopies = true;
    await harness.queue.reconcile();
    expect(harness.manager.copies, [4985, 4985, 4985]);
    expect(harness.manager.maxActive, 1);
    expect(harness.container.read(localDownloadQueueProvider)[4985]?.status,
        LocalCacheStatus.failed);
    expect(
        OperationLog.instance.value
            .where((entry) => entry.contains('OfflineChapterCache failed')),
        hasLength(3));
    harness.manager.failCopies = false;
    harness.queue.retry(197, 4985);
    await harness.queue.reconcile();
    expect(harness.container.read(localDownloadQueueProvider)[4985]?.status,
        LocalCacheStatus.done);
  });

  test('invalid pagination stops with a visible diagnostic rather than looping',
      () async {
    final harness = CacheHarness(
        (_) => candidatePage([], hasNext: true, cursor: 'unchanged'));
    addTearDown(harness.dispose);
    await harness.queue.reconcile();
    expect(harness.requests, hasLength(2));
    expect(OperationLog.instance.exportText(),
        contains('OfflineCacheCatchUp failed'));
  });

  test('query and disk failures are logged without leaking error text',
      () async {
    final failedQuery = CacheHarness((_) => Response(
          response: const {},
          errors: [GraphQLError(message: 'private-server-url')],
        ));
    addTearDown(failedQuery.dispose);
    await failedQuery.queue.reconcile();
    expect(OperationLog.instance.exportText(),
        contains('OfflineCacheCatchUp failed'));
    expect(OperationLog.instance.exportText(), isNot(contains('private-server')));

    final failedDisk = CacheHarness((_) => candidatePage([]));
    addTearDown(failedDisk.dispose);
    failedDisk.container.read(offlineChapterManagerProvider);
    failedDisk.manager.failChecks = true;
    await failedDisk.queue.enqueue(197, 4985);
    expect(failedDisk.container.read(localDownloadQueueProvider)[4985]?.status,
        LocalCacheStatus.failed);
    expect(OperationLog.instance.exportText(),
        contains('OfflineChapterCache failed mangaId=197 chapterId=4985'));
    expect(OperationLog.instance.exportText(), isNot(contains('private-server')));
  });

  testWidgets('Save on device for a read server-only chapter is local-only',
      (tester) async {
    final harness = CacheHarness((_) => candidatePage([]), overrides: [
      downloadsFromIdProvider(4985).overrideWith((ref) => null),
      isChapterOfflineProvider(mangaId: 197, chapterId: 4985)
          .overrideWith((ref) async => false),
      toastProvider.overrideWith((ref) => null),
    ]);
    addTearDown(harness.dispose);
    final chapter = chapterFromJson({
      '__typename': 'ChapterType',
      'id': 4985,
      'mangaId': 197,
      'chapterNumber': 286.0,
      'fetchedAt': '0',
      'isBookmarked': false,
      'isDownloaded': true,
      'isRead': true,
      'lastPageRead': 0,
      'lastReadAt': '0',
      'name': 'Chapter 286',
      'pageCount': 18,
      'sourceOrder': 286,
      'uploadDate': '0',
      'url': '/chapter/286',
      'meta': [],
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: DownloadStatusIcon(
              updateData: () async {},
              chapter: chapter,
              mangaId: 197,
              isDownloaded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save on device'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Save on device'));
    await tester.pumpAndSettle();
    expect(harness.manager.copies, [4985]);
    expect(harness.requests, isEmpty,
        reason: 'Must not delete, enqueue, or restart a server download');
    expect(find.byTooltip('Available offline'), findsOneWidget);
  });

  testWidgets(
      'root waits for configuration/auth and safely catches up on lifecycle/reconnect',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final operations = <String>[];
    final client = GraphQLClient(
      cache: GraphQLCache(),
      link: Link.function((request, [forward]) async* {
        final operation = request.operation.operationName!;
        operations.add(operation);
        if (operation == 'DownloadStatusChanged') {
          yield Response(response: const {}, data: {
            '__typename': 'Subscription',
            'downloadStatusChanged': {
              '__typename': 'DownloadUpdates',
              'state': 'STOPPED',
              'initial': [],
              'updates': [],
              'omittedUpdates': false,
            },
          });
        } else {
          yield candidatePage([]);
        }
      }),
    );
    // Keep navigation inert to isolate root sync wiring from existing screens'
    // own queries. Do not stub the queue/notifier/lifecycle integration.
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('Root'))),
      ],
    );
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      graphQlClientProvider.overrideWithValue(client),
      graphQlSubscriptionClientProvider.overrideWithValue(client),
      routerConfigProvider.overrideWithValue(router),
      connectivityStatusProvider.overrideWith(ControlledConnectivity.new),
    ]);
    try {
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const Sorayomi(),
      ));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 5));
      expect(tester.takeException(), isNull);
      expect(operations, isEmpty,
          reason: 'Unconfigured startup/polling must not start a worker');

      container.read(authTypeKeyProvider.notifier).update(AuthType.uiLogin);
      container
          .read(serverUrlProvider.notifier)
          .update('http://server.test');
      await tester.pumpAndSettle();
      expect(operations, isEmpty,
          reason: 'Configured UI Login must wait for sign-in');

      container
          .read(uiLoginAccessTokenProvider.notifier)
          .update('test-access-token');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(operations, contains('GetOfflineCacheCandidates'));
      expect(operations, contains('DownloadStatusChanged'));

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      final pausedCount = operations.length;
      await tester.pump(const Duration(minutes: 5));
      expect(operations, hasLength(pausedCount));

      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(operations.length, greaterThan(pausedCount));

      final connectivity = container.read(connectivityStatusProvider.notifier)
          as ControlledConnectivity;
      connectivity.setOnline(false);
      await tester.pumpAndSettle();
      final disconnectedCount = operations.length;
      connectivity.setOnline(true);
      await tester.pumpAndSettle();
      expect(operations.length, greaterThan(disconnectedCount));

      container.read(uiLoginAccessTokenProvider.notifier).update(null);
      await tester.pumpAndSettle();
      final signedOutCount = operations.length;
      await tester.pump(const Duration(minutes: 5));
      expect(operations, hasLength(signedOutCount));
      expect(operations.toSet(),
          {'GetOfflineCacheCandidates', 'DownloadStatusChanged'});
      expect(tester.takeException(), isNull);
      expect(
          OperationLog.instance.value.where(
              (entry) => entry.contains('OfflineCacheCatchUp failed')),
          isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      router.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
