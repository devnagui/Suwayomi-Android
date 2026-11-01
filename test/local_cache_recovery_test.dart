import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql/client.dart';
import 'package:path/path.dart' as p;
import 'package:tachidesk_sorayomi/src/features/settings/data/local_cache_repository.dart';
import 'package:tachidesk_sorayomi/src/utils/extensions/custom_extensions.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/logger_link.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/mutation_cache.dart';

Response existingMangas(Iterable<int> ids) => Response(
      response: const {},
      data: {
        '__typename': 'Query',
        'mangas': {
          '__typename': 'MangaNodeList',
          'nodes': [
            for (final id in ids) {'__typename': 'MangaType', 'id': id},
          ],
        },
      },
    );

void main() {
  late Directory directory;
  late MutationCache mutationCache;
  late InMemoryStore store;
  late OperationLog log;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sorayomi-recovery-');
    final cacheDirectory =
        await Directory(p.join(directory.path, 'mutation_cache')).create();
    mutationCache = MutationCache.forDirectory(cacheDirectory);
    store = InMemoryStore({
      'MangaType:1': {'__typename': 'MangaType', 'id': 1},
      'MangaType:2': {'__typename': 'MangaType', 'id': 2},
    });
    log = OperationLog();
  });

  tearDown(() async {
    log.dispose();
    await directory.delete(recursive: true);
  });

  LocalCacheRepository repository(Link link) => LocalCacheRepository(
        GraphQLClient(link: link, cache: GraphQLCache(store: store)),
        mutationCache,
        clearImages: () async {},
        operationLog: log,
      );

  Future<void> seedChapters() async {
    for (final mangaId in [1, 2]) {
      final chapterId = mangaId * 10;
      final chapter = {'id': chapterId, 'mangaId': mangaId};
      await mutationCache.put('chapter_list_$mangaId', [chapter]);
      await mutationCache.put('chapter_$chapterId', chapter);
      await mutationCache.put('chapter_pages_$chapterId', {
        'pages': ['/page.jpg']
      });
    }
  }

  test(
      'missing lookup deletes only orphan mutation metadata and resets stale queries',
      () async {
    await seedChapters();
    final savedPage =
        File(p.join(directory.path, 'offline_manga', '1', '10', '0.jpg'));
    await savedPage.parent.create(recursive: true);
    await savedPage.writeAsString('saved page');
    final requests = <Request>[];
    final repo = repository(Link.function((request, [forward]) async* {
      requests.add(request);
      expect(request.variables['ids'], [1, 2]);
      yield existingMangas([2]);
    }));

    expect(await repo.removeMissingMangaLinks(), 1);
    expect(await mutationCache.get('chapter_10'), isNull);
    expect(await mutationCache.get('chapter_pages_10'), isNull);
    expect(await mutationCache.get('chapter_list_1'), isNull);
    expect(await mutationCache.get('chapter_20'), isNotNull);
    expect(store.toMap(), isEmpty);
    expect(await savedPage.readAsString(), 'saved page');
    expect(
        requests.single.operation.document.definitions
            .whereType<OperationDefinitionNode>()
            .single
            .type,
        OperationType.query);
  });

  test('existing IDs do not remove valid cached data', () async {
    await seedChapters();
    final repo = repository(Link.function((request, [forward]) async* {
      yield existingMangas([1, 2]);
    }));
    expect(await repo.removeMissingMangaLinks(), 0);
    expect(store.toMap(), hasLength(2));
    expect(await mutationCache.entries(), hasLength(6));
  });

  for (final failure in ['Unauthorized', 'Forbidden', 'Server unavailable']) {
    test('$failure is not interpreted as missing manga', () async {
      await seedChapters();
      final before = await mutationCache.entries();
      final graphBefore = store.toMap();
      final repo = repository(Link.function((request, [forward]) async* {
        yield Response(
          response: const {},
          errors: [GraphQLError(message: failure)],
        );
      }));
      await expectLater(repo.removeMissingMangaLinks(),
          throwsA(isA<OperationMessageException>()));
      expect(await mutationCache.entries(), before);
      expect(store.toMap(), graphBefore);
      expect(log.value.last, contains('failed'));
    });
  }

  test('network failure never deletes cached entries', () async {
    await seedChapters();
    final before = await mutationCache.entries();
    final repo = repository(Link.function((request, [forward]) {
      return Stream.error(NetworkException.fromException(
        originalException: const SocketException('offline'),
        originalStackTrace: StackTrace.empty,
        uri: null,
      ));
    }));
    await expectLater(repo.removeMissingMangaLinks(),
        throwsA(isA<OperationMessageException>()));
    expect(await mutationCache.entries(), before);
    expect(store.toMap(), hasLength(2));
  });

  test('all batches must succeed before any orphan is deleted', () async {
    store.putAll({
      for (var id = 3; id <= 201; id++)
        'MangaType:$id': {'__typename': 'MangaType', 'id': id},
    });
    await seedChapters();
    var batches = 0;
    final repo = repository(Link.function((request, [forward]) async* {
      final ids = (request.variables['ids'] as List).cast<int>();
      expect(ids.length, lessThanOrEqualTo(100));
      batches++;
      if (batches == 3) {
        yield Response(
          response: const {},
          errors: [GraphQLError(message: 'Backend failed')],
        );
      } else {
        yield existingMangas([]);
      }
    }));
    await expectLater(repo.removeMissingMangaLinks(),
        throwsA(isA<OperationMessageException>()));
    expect(batches, 3);
    expect(store.toMap(), hasLength(201));
    expect(await mutationCache.entries(), hasLength(6));
  });

  test('unexpected lookup IDs abort cleanup', () async {
    final repo = repository(Link.function((request, [forward]) async* {
      yield existingMangas([999]);
    }));
    await expectLater(repo.removeMissingMangaLinks(), throwsStateError);
    expect(store.toMap(), hasLength(2));
  });

  test('force-forget works locally without a server request', () async {
    await seedChapters();
    var requests = 0;
    final repo = repository(Link.function((request, [forward]) async* {
      requests++;
      throw StateError('Server must not be contacted');
    }));
    expect(await repo.forgetManga(1), 1);
    expect(requests, 0);
    expect(await mutationCache.get('chapter_10'), isNull);
    expect(await mutationCache.get('chapter_20'), isNotNull);
    expect(store.toMap(), isEmpty);
  });

  test('cleared phantom references stay removed after reopening Hive',
      () async {
    final path = p.join(directory.path, 'graphql-cache');
    await Directory(path).create();
    final hive =
        await HiveStore.open(boxName: 'cache-recovery-test', path: path);
    addTearDown(() async {
      if (hive.box.isOpen) await hive.box.close();
    });
    hive.put('MangaType:37', {'__typename': 'MangaType', 'id': 37});
    await hive.box.flush();
    final repo = LocalCacheRepository(
      GraphQLClient(
        link: Link.function((request, [forward]) async* {}),
        cache: GraphQLCache(store: hive),
      ),
      mutationCache,
      clearImages: () async {},
    );
    await repo.forgetManga(37);
    await hive.box.close();
    final reopened = await HiveStore.open(
      boxName: 'cache-recovery-test',
      path: path,
    );
    addTearDown(() async {
      if (reopened.box.isOpen) await reopened.box.close();
    });
    expect(reopened.toMap(), isEmpty);
    await reopened.box.close();
  });

  test('clear repairs corrupt cache files but preserves other local files',
      () async {
    final corrupt =
        File(p.join(directory.path, 'mutation_cache', 'chapter_10.json'));
    await corrupt.writeAsString('{bad json');
    final other = File(p.join(directory.path, 'mutation_cache', 'notes.txt'));
    await other.writeAsString('keep');
    final saved = File(p.join(directory.path, 'offline_manga', 'page.jpg'));
    await saved.parent.create(recursive: true);
    await saved.writeAsString('saved');
    final repo = repository(Link.function((request, [forward]) async* {
      throw StateError('No network needed');
    }));
    expect(await repo.clearLocalCache(), 1);
    expect(await corrupt.exists(), isFalse);
    expect(await other.readAsString(), 'keep');
    expect(await saved.readAsString(), 'saved');
    expect(store.toMap(), isEmpty);
  });

  test('concurrent cache operations are rejected explicitly', () async {
    final images = Completer<void>();
    final repo = LocalCacheRepository(
      GraphQLClient(
        link: Link.function((request, [forward]) async* {}),
        cache: GraphQLCache(store: store),
      ),
      mutationCache,
      clearImages: () => images.future,
    );
    final clearing = repo.clearLocalCache();
    await expectLater(repo.forgetManga(1), throwsStateError);
    images.complete();
    await clearing;
  });

  group('network-first library reads', () {
    late GraphQLClient client;
    late QueryOptions<Object?> options;
    late Response Function() response;

    setUp(() {
      options = QueryOptions(
        document:
            gql('query LibrarySnapshot { items { id __typename } __typename }'),
      );
      response = () => Response(
            response: const {},
            data: {'__typename': 'Query', 'items': <dynamic>[]},
          );
      client = GraphQLClient(
        link: Link.function((request, [forward]) async* {
          yield response();
        }),
        cache: GraphQLCache(),
        defaultPolicies: DefaultPolicies(
          query: Policies(fetch: FetchPolicy.cacheAndNetwork),
        ),
      );
      client.cache.writeQuery(options.asRequest, data: {
        '__typename': 'Query',
        'items': [
          {'id': 1, '__typename': 'MangaType'}
        ],
      });
    });

    test('fresh server list replaces an eager phantom cached list', () async {
      final result = await networkFirstQuery(
        (policy) => client.query(QueryOptions<Object?>(
          document: options.document,
          fetchPolicy: policy,
        )),
      );
      expect(result.data?['items'], isEmpty);
      expect(result.source, QueryResultSource.network);
    });

    test('connection failure retains explicitly logged offline access',
        () async {
      response = () => throw NetworkException.fromException(
            originalException: const SocketException('offline'),
            originalStackTrace: StackTrace.empty,
            uri: null,
          );
      final result = await networkFirstQuery(
        (policy) => client.query(QueryOptions<Object?>(
          document: options.document,
          fetchPolicy: policy,
        )),
      );
      expect(result.hasException, isFalse);
      expect(result.data?['items'], hasLength(1));
      expect(result.source, QueryResultSource.cache);
    });

    test('permission errors do not fall back to stale library data', () async {
      response = () => Response(
            response: const {},
            errors: [GraphQLError(message: 'Unauthorized')],
          );
      final result = await networkFirstQuery(
        (policy) => client.query(QueryOptions<Object?>(
          document: options.document,
          fetchPolicy: policy,
        )),
      );
      expect(result.hasException, isTrue);
      expect(result.exception?.graphqlErrors.single.message, 'Unauthorized');
    });
  });

  test('operation logs are bounded and can be cleared', () {
    final bounded = OperationLog(capacity: 3);
    addTearDown(bounded.dispose);
    for (var i = 0; i < 10; i++) {
      bounded.record('Step$i', outcome: 'completed');
    }
    expect(bounded.value, hasLength(3));
    expect(bounded.value.first, contains('Step7'));
    expect(bounded.value.last, contains('Step9'));
    bounded.clear();
    expect(bounded.value, isEmpty);
    expect(() => OperationLog(capacity: 0), throwsArgumentError);
  });

  test('GraphQL diagnostics never include credentials or response bodies',
      () async {
    final request = Request(
      operation: Operation(
        document: gql('query GetManga { __typename }'),
        operationName: 'GetManga',
      ),
      variables: {
        'id': 37,
        'password': 'secret-password',
        'authorization': 'Bearer secret-token',
        'input': {'mangaId': 37, 'refreshToken': 'secret-refresh'},
      },
    );
    final response = Response(
      response: {'password': 'secret-password'},
      data: {
        'mangas': {
          'nodes': [
            {'title': 'private-title', 'url': 'https://private-server'}
          ],
        },
      },
      errors: [GraphQLError(message: 'private-error secret-token')],
    );
    final result = await LoggerLink(operationLog: log)
        .request(
          request,
          (_) => Stream.value(response),
        )
        .single;
    expect(result, same(response));
    final exported = log.exportText();
    expect(exported, contains('GetManga'));
    expect(exported, contains('id=37'));
    expect(exported, contains('count=1'));
    expect(exported, contains('graphql_error'));
    for (final sensitive in [
      'secret-password',
      'secret-token',
      'secret-refresh',
      'private-title',
      'private-server',
      'private-error',
    ]) {
      expect(exported, isNot(contains(sensitive)));
    }
  });

  test('logging preserves prompt cancellation of long-lived streams', () async {
    final cancelled = Completer<void>();
    final source = StreamController<Response>(
      onCancel: () => cancelled.complete(),
    );
    final request = Request(
      operation: Operation(document: gql('subscription Test { __typename }')),
    );
    final subscription = LoggerLink(operationLog: log)
        .request(request, (_) => source.stream)
        .listen((_) {});
    await subscription.cancel().timeout(const Duration(milliseconds: 500));
    expect(cancelled.isCompleted, isTrue);
    await source.close();
  });

  test('transport failures are recorded without swallowing the original error',
      () async {
    final error = NetworkException.fromException(
      originalException: const SocketException('private transport details'),
      originalStackTrace: StackTrace.empty,
      uri: Uri.parse('https://private-server'),
    );
    final request = Request(
      operation: Operation(document: gql('query Test { __typename }')),
    );
    await expectLater(
      LoggerLink(operationLog: log)
          .request(request, (_) => Stream.error(error))
          .toList(),
      throwsA(same(error)),
    );
    expect(log.exportText(), contains('transport_error'));
    expect(log.exportText(), isNot(contains('private-server')));
  });
}
