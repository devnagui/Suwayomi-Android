import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/manga/manga_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/manga_details/controller/manga_details_controller.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/extensions/custom_extensions.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/mutation_cache.dart';

import 'chapter_download_regression_test.dart' show chapter;

class _EmptyManga extends MangaWithId {
  @override
  Future<MangaDto?> build({required int mangaId}) async => null;
}

class _RecordingCache extends MutationCache {
  _RecordingCache(super.directory) : super.forDirectory();

  final writes = <String>[];

  @override
  Future<void> put(String key, dynamic jsonData) {
    writes.add(key);
    return super.put(key, jsonData);
  }
}

List<int>? requestedIds(Request request) {
  final filter = request.variables['filter'];
  if (filter is! Map) return null;
  final idFilter = filter['id'];
  if (idFilter is! Map) return null;
  final ids = idFilter['in'];
  return ids is List ? ids.cast<int>() : null;
}

Response chapterPage(List<int> ids,
        {bool hasNext = false, String? cursor, int? totalCount}) =>
    chapterDataPage([for (final id in ids) chapter(id)],
        hasNext: hasNext, cursor: cursor, totalCount: totalCount);

Response chapterDataPage(List<ChapterDto> chapters,
        {bool hasNext = false, String? cursor, int? totalCount}) =>
    Response(response: const {}, data: {
      '__typename': 'Query',
      'chapters': {
        '__typename': 'ChapterNodeList',
        'nodes': [for (final chapter in chapters) chapter.toJson()],
        'totalCount': totalCount ?? chapters.length,
        'pageInfo': {
          '__typename': 'PageInfo',
          'hasNextPage': hasNext,
          'hasPreviousPage': false,
          'startCursor': null,
          'endCursor': cursor,
        },
      },
    });

void main() {
  late Directory directory;
  late _RecordingCache cache;
  late SharedPreferences preferences;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chapter-list-');
    cache = _RecordingCache(directory);
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    OperationLog.instance.clear();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  ProviderContainer containerFor(Link link) {
    final client = GraphQLClient(link: link, cache: GraphQLCache());
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      mangaWithIdProvider(mangaId: 37).overrideWith(_EmptyManga.new),
      mangaBookRepositoryProvider.overrideWith(
        (ref) => MangaBookRepository(client, ref, cache: cache),
      ),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test(
      'stored server chapter 288 replaces an older local list without source fetch',
      () async {
    await cache.put('chapter_list_37', [chapter(287).toJson()]);
    final requests = <Request>[];
    final container = containerFor(Link.function((request, [forward]) async* {
      requests.add(request);
      yield chapterPage(requestedIds(request) ?? [287, 288]);
    }));

    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);

    expect(result?.map((c) => c.id), [287, 288]);
    expect(requests, hasLength(2));
    expect(requests.first.operation.operationName, 'GetChapterIndex');
    expect(requests.first.variables['mangaId'], 37);
    expect(printNode(requests.first.operation.document),
        isNot(contains('ChapterDto')));
    expect(requests.last.variables['condition'], {'mangaId': 37});
    expect(requestedIds(requests.last), [288]);
    expect(
        requests.first.operation.document.definitions
            .whereType<OperationDefinitionNode>()
            .single
            .type,
        OperationType.query);
    expect((await cache.get('chapter_list_37') as List), hasLength(2));
    expect(await cache.get('chapter_288'), isNotNull);
  });

  test('chapter list follows opaque cursors to include later pages', () async {
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      if (requests == 1) {
        yield chapterPage([287], hasNext: true, cursor: 'opaque:next');
      } else {
        expect(request.variables['after'], 'opaque:next');
        yield chapterPage([288]);
      }
    }));

    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.map((c) => c.id), [287, 288]);
    expect(requests, 2);
  });

  test(
      'opening a chapter refreshes its server position instead of a stale query',
      () async {
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      final fresh = chapter(84).copyWith(
          user: chapter(84).user.copyWith(
                lastPageRead: requests == 1 ? 1 : 7,
                lastReadAt: '${2000000000 + requests}',
              ));
      yield Response(response: const {}, data: {
        '__typename': 'Query',
        'chapter': fresh.toJson(),
      });
    }));
    final repository = container.read(mangaBookRepositoryProvider);
    expect((await repository.getChapter(chapterId: 84))?.lastPageRead, 1);
    expect((await repository.getChapter(chapterId: 84))?.lastPageRead, 7);
    expect(requests, 2);
  });

  test('chapter-filter diagnostics remain visible in structured logs',
      () async {
    final container = containerFor(Link.function((request, [forward]) async* {
      yield chapterPage([287, 288]);
    }));
    final provider = mangaChapterListProvider(mangaId: 37);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
    await container.read(mangaWithIdProvider(mangaId: 37).future);
    final result =
        container.read(mangaChapterListWithFilterProvider(mangaId: 37));
    expect(result.hasError, isFalse, reason: result.error?.toString());
    expect(result.valueOrNull?.map((c) => c.id), containsAll([287, 288]));
    final event = OperationLog.instance.latestEvent('MangaChapterFilter');
    expect(event?['count'], 2);
    expect(event?['action'],
        'unread_null_downloaded_null_bookmarked_null_scanlator_false');
  });

  test(
      'reloading a retained manga list includes chapters added by server updates',
      () async {
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      yield chapterPage(
          requestedIds(request) ?? (requests == 1 ? [287] : [287, 288]));
    }));
    final provider = mangaChapterListProvider(mangaId: 37);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
    await container.read(provider.notifier).refresh();
    expect(container.read(provider).valueOrNull?.map((c) => c.id), [287, 288]);
    expect(requests, 3);
  });

  test('unchanged cache fetches no full details and writes no metadata',
      () async {
    final chapters = [for (var id = 1; id <= 287; id++) chapter(id)];
    await cache.put(
        'chapter_list_37', chapters.map((c) => c.toJson()).toList());
    cache.writes.clear();
    final requests = <Request>[];
    final container = containerFor(Link.function((request, [forward]) async* {
      requests.add(request);
      yield chapterDataPage(chapters);
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result, hasLength(287));
    expect(requests, hasLength(1));
    expect(requests.single.operation.operationName, 'GetChapterIndex');
    expect(cache.writes, isEmpty);
    expect(OperationLog.instance.latestEvent('MangaChapterSync')?['count'], 0);
  });

  test(
      'one new chapter fetches only its details and saves only changed metadata',
      () async {
    final old = [for (var id = 1; id <= 287; id++) chapter(id)];
    await cache.put('chapter_list_37', old.map((c) => c.toJson()).toList());
    cache.writes.clear();
    final requests = <Request>[];
    final container = containerFor(Link.function((request, [forward]) async* {
      requests.add(request);
      yield chapterPage(requestedIds(request) ??
          [
            for (var id = 1; id <= 288; id++) id,
          ]);
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result, hasLength(288));
    expect(requests, hasLength(2));
    expect(requestedIds(requests.last), [288]);
    expect(cache.writes, ['chapter_list_37', 'chapter_288']);
    expect(OperationLog.instance.latestEvent('MangaChapterSync')?['count'], 1);
  });

  test('status, page count and source ordering refresh without full details',
      () async {
    final old = chapter(287);
    final updated = old.copyWith(
      sourceOrder: 0,
      pageCount: 18,
      user: old.user.copyWith(
        isRead: true,
        isDownloaded: true,
        isBookmarked: true,
        lastPageRead: 17,
        lastReadAt: '1720000200',
      ),
    );
    await cache.put('chapter_list_37', [old.toJson()]);
    cache.writes.clear();
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      expect(request.operation.operationName, 'GetChapterIndex');
      yield chapterDataPage([updated]);
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.single, updated);
    expect(requests, 1);
    expect(cache.writes, ['chapter_list_37', 'chapter_287']);
  });

  test(
      'late-added lower IDs are discovered instead of using chapter-number cutoff',
      () async {
    await cache.put('chapter_list_37', [chapter(288).toJson()]);
    final container = containerFor(Link.function((request, [forward]) async* {
      if (requestedIds(request) case final ids?) {
        expect(ids, [100]);
        yield chapterDataPage([chapter(100).copyWith(chapterNumber: 5)]);
      } else {
        yield chapterPage([100, 288]);
      }
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.map((c) => c.id), [100, 288]);
    expect(result?.first.chapterNumber, 5);
  });

  test('reused ID with changed URL reloads full metadata', () async {
    await cache.put('chapter_list_37', [chapter(287).toJson()]);
    final replacement = chapter(287).copyWith(url: '/replacement', name: 'New');
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      if (requestedIds(request) case final ids?) expect(ids, [287]);
      yield chapterDataPage([replacement]);
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.single, replacement);
    expect(requests, 2);
  });

  test('missing IDs are fetched in bounded batches', () async {
    await cache.put('chapter_list_37', [chapter(1).toJson()]);
    final batches = <List<int>>[];
    final container = containerFor(Link.function((request, [forward]) async* {
      if (requestedIds(request) case final ids?) {
        batches.add(ids);
        yield chapterPage(ids);
      } else {
        yield chapterPage([for (var id = 1; id <= 252; id++) id]);
      }
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result, hasLength(252));
    expect(batches.map((b) => b.length), [100, 100, 51]);
    expect(batches.expand((b) => b), [for (var id = 2; id <= 252; id++) id]);
  });

  test('incremental index follows cursors and validates completeness',
      () async {
    await cache.put('chapter_list_37', [chapter(1).toJson()]);
    var indexRequests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      if (requestedIds(request) case final ids?) {
        yield chapterPage(ids);
      } else if (++indexRequests == 1) {
        yield chapterPage([1],
            hasNext: true, cursor: 'opaque:index', totalCount: 2);
      } else {
        expect(request.variables['after'], 'opaque:index');
        yield chapterPage([2], totalCount: 2);
      }
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.map((c) => c.id), [1, 2]);
    expect(indexRequests, 2);
  });

  test('incomplete detail response never overwrites the existing cache',
      () async {
    await cache.put('chapter_list_37', [chapter(1).toJson()]);
    cache.writes.clear();
    final container = containerFor(Link.function((request, [forward]) async* {
      yield chapterPage(requestedIds(request) == null ? [1, 2] : []);
    }));
    await expectLater(
        container.read(mangaBookRepositoryProvider).getChapterList(37),
        throwsStateError);
    expect(cache.writes, isEmpty);
    expect((await cache.get('chapter_list_37') as List).single['id'], 1);
  });

  for (final invalid in ['duplicate', 'wrong_manga', 'incomplete_count']) {
    test('$invalid index cannot overwrite the cache', () async {
      await cache.put('chapter_list_37', [chapter(1).toJson()]);
      cache.writes.clear();
      final container = containerFor(Link.function((request, [forward]) async* {
        yield chapterDataPage(
          switch (invalid) {
            'duplicate' => [chapter(1), chapter(1)],
            'wrong_manga' => [chapter(1).copyWith(mangaId: 99)],
            _ => [chapter(1)],
          },
          totalCount: invalid == 'incomplete_count' ? 2 : null,
        );
      }));
      await expectLater(
          container.read(mangaBookRepositoryProvider).getChapterList(37),
          throwsStateError);
      expect(cache.writes, isEmpty);
    });
  }

  test('empty server index removes stale entries without fetching the source',
      () async {
    await cache.put('chapter_list_37', [chapter(1).toJson()]);
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      expect(request.operation.operationName, 'GetChapterIndex');
      yield chapterPage([]);
    }));
    expect(await container.read(mangaBookRepositoryProvider).getChapterList(37),
        isEmpty);
    expect(requests, 1);
  });

  test('manual source refresh replaces cached text metadata too', () async {
    final old = chapter(1);
    final updated =
        old.copyWith(name: 'Corrected title', scanlator: 'Corrected');
    await cache.put('chapter_list_37', [old.toJson()]);
    final container = containerFor(Link.function((request, [forward]) async* {
      yield Response(response: const {}, data: {
        '__typename': 'Mutation',
        'fetchChapters': {
          '__typename': 'FetchMangaAndChaptersPayload',
          'chapters': [updated.toJson()],
        },
      });
    }));
    expect(
        (await container.read(mangaBookRepositoryProvider).fetchChapterList(37))
            ?.single,
        updated);
    expect((await cache.get('chapter_1'))['name'], updated.name);
  });

  test('successful removals update membership without deleting offline files',
      () async {
    await cache
        .put('chapter_list_37', [chapter(1).toJson(), chapter(2).toJson()]);
    final page = File('${directory.path}${Platform.pathSeparator}offline.jpg');
    await page.writeAsString('offline page');
    final container = containerFor(Link.function((request, [forward]) async* {
      yield chapterPage([2]);
    }));
    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.map((c) => c.id), [2]);
    expect(await page.readAsString(), 'offline page');
  });

  test('corrupt cache is logged and repaired from a full server query',
      () async {
    await cache.put('chapter_list_37', ['invalid']);
    final container = containerFor(Link.function((request, [forward]) async* {
      expect(request.operation.operationName, 'GetChapterPage');
      yield chapterPage([288]);
    }));
    expect(
        (await container.read(mangaBookRepositoryProvider).getChapterList(37))
            ?.single
            .id,
        288);
    expect(OperationLog.instance.value.any((e) => e.contains('cache_invalid')),
        isTrue);
  });

  test('invalid pagination never overwrites the complete cache', () async {
    await cache.put('chapter_list_37', [chapter(288).toJson()]);
    final container = containerFor(Link.function((request, [forward]) async* {
      yield chapterPage([287], hasNext: true);
    }));
    await expectLater(
      container.read(mangaBookRepositoryProvider).getChapterList(37),
      throwsStateError,
    );
    expect((await cache.get('chapter_list_37') as List).single['id'], 288);
  });

  for (final error in ['Source fetch failed', 'Unauthorized', 'Forbidden']) {
    test('$error is surfaced instead of hiding behind an old chapter list',
        () async {
      await cache.put('chapter_list_37', [chapter(287).toJson()]);
      final container = containerFor(Link.function((request, [forward]) async* {
        yield Response(
            response: const {}, errors: [GraphQLError(message: error)]);
      }));
      await expectLater(
        container.read(mangaBookRepositoryProvider).getChapterList(37),
        throwsA(isA<OperationMessageException>()),
      );
    });
  }

  test(
      'network outage preserves offline chapter metadata with explicit logging',
      () async {
    await cache.put('chapter_list_37', [chapter(288).toJson()]);
    final container = containerFor(Link.function(
        (request, [forward]) => Stream.error(NetworkException.fromException(
              originalException: const SocketException('offline'),
              originalStackTrace: StackTrace.empty,
              uri: null,
            ))));

    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);
    expect(result?.single.id, 288);
    expect(OperationLog.instance.value.last, contains('offline_cache'));
  });

  test('manual refresh still fetches chapters from the source', () async {
    final operations = <OperationType>[];
    final container = containerFor(Link.function((request, [forward]) async* {
      final type = request.operation.document.definitions
          .whereType<OperationDefinitionNode>()
          .single
          .type;
      operations.add(type);
      if (type == OperationType.query) {
        yield chapterPage([287]);
      } else {
        expect(request.variables['input']['fetchChapters'], isTrue);
        yield Response(response: const {}, data: {
          '__typename': 'Mutation',
          'fetchChapters': {
            '__typename': 'FetchMangaAndChaptersPayload',
            'chapters': [chapter(287).toJson(), chapter(288).toJson()],
          },
        });
      }
    }));
    final provider = mangaChapterListProvider(mangaId: 37);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
    await container.read(provider.notifier).refresh(true);
    expect(container.read(provider).hasError, isFalse);
    expect(container.read(provider).valueOrNull?.map((c) => c.id), [287, 288]);
    expect(operations, [OperationType.query, OperationType.mutation]);
  });

  test('first open of an uninitialized manga fetches its source chapters',
      () async {
    var requests = 0;
    final container = containerFor(Link.function((request, [forward]) async* {
      requests++;
      if (requests == 1) {
        yield chapterPage([]);
      } else {
        yield Response(response: const {}, data: {
          '__typename': 'Mutation',
          'fetchChapters': {
            '__typename': 'FetchMangaAndChaptersPayload',
            'chapters': [chapter(288).toJson()],
          },
        });
      }
    }));
    expect(
        (await container.read(mangaBookRepositoryProvider).getChapterList(37))
            ?.single
            .id,
        288);
    expect(requests, 2);
  });
}
