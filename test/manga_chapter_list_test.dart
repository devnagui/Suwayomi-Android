import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
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

Response chapterPage(List<int> ids, {bool hasNext = false, String? cursor}) =>
    Response(response: const {}, data: {
      '__typename': 'Query',
      'chapters': {
        '__typename': 'ChapterNodeList',
        'nodes': [for (final id in ids) chapter(id).toJson()],
        'totalCount': ids.length,
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
  late MutationCache cache;
  late SharedPreferences preferences;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chapter-list-');
    cache = MutationCache.forDirectory(directory);
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
      expect(request.variables['condition'], {'mangaId': 37});
      yield chapterPage([287, 288]);
    }));

    final result =
        await container.read(mangaBookRepositoryProvider).getChapterList(37);

    expect(result?.map((c) => c.id), [287, 288]);
    expect(requests, hasLength(1));
    expect(
        requests.single.operation.document.definitions
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
      yield chapterPage(requests == 1 ? [287] : [287, 288]);
    }));
    final provider = mangaChapterListProvider(mangaId: 37);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);
    await container.read(provider.future);
    await container.read(provider.notifier).refresh();
    expect(container.read(provider).valueOrNull?.map((c) => c.id), [287, 288]);
    expect(requests, 2);
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
