import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../global_providers/global_providers.dart';
import '../../../utils/extensions/custom_extensions.dart';
import '../../../utils/logger/operation_log.dart';
import '../../../utils/network/manga_cache_manager.dart';
import '../../../utils/network/mutation_cache.dart';
import 'graphql/__generated__/query.graphql.dart';

class LocalCacheRepository {
  LocalCacheRepository(
    this.client,
    this.mutationCache, {
    Future<void> Function()? clearImages,
    OperationLog? operationLog,
  })  : clearImages = clearImages ?? _clearImages,
        operationLog = operationLog ?? OperationLog.instance;

  final GraphQLClient client;
  final MutationCache mutationCache;
  final Future<void> Function() clearImages;
  final OperationLog operationLog;
  bool _busy = false;

  static Future<void> _clearImages() async {
    await DefaultCacheManager().emptyCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  Future<void> _clearQueryCache() async {
    final store = client.cache.store;
    if (store is HiveStore) {
      await store.reset();
    } else {
      store.reset();
    }
  }

  Future<int> _run(String operation, Future<int> Function() action) async {
    if (_busy) throw StateError('A local cache operation is already running');
    _busy = true;
    operationLog.record(operation, outcome: 'started');
    try {
      final result = await AsyncValue.guard(action);
      if (result.hasError) {
        operationLog.record(
          operation,
          outcome: 'failed',
          errorType: result.error.runtimeType.toString(),
        );
        Error.throwWithStackTrace(result.error!, result.stackTrace!);
      }
      final count = result.requireValue;
      operationLog.record(operation, outcome: 'completed', count: count);
      return count;
    } finally {
      _busy = false;
    }
  }

  Future<int> clearLocalCache() => _run('ClearLocalCache', () async {
        final removed = await mutationCache.clear();
        await _clearQueryCache();
        await clearImages();
        return removed;
      });

  Future<int> forgetManga(int mangaId) {
    if (mangaId < 0) throw ArgumentError.value(mangaId, 'mangaId');
    return _run('ForgetLocalManga', () async {
      await mutationCache.removeMangas({mangaId});
      await _clearQueryCache();
      return 1;
    });
  }

  Future<int> removeMissingMangaLinks() =>
      _run('RemoveMissingMangaLinks', () async {
        final snapshot = await mutationCache.entries();
        final ids = <int>{};
        void collect(dynamic value) {
          if (value is Map) {
            if (value['__typename'] == 'MangaType' && value['id'] is int) {
              ids.add(value['id'] as int);
            }
            if (value['mangaId'] is int) ids.add(value['mangaId'] as int);
            for (final nested in value.values) {
              collect(nested);
            }
          } else if (value is List) {
            for (final nested in value) {
              collect(nested);
            }
          }
        }

        final graphCache = client.cache.store.toMap();
        collect(graphCache);
        collect(snapshot);
        for (final key in [...graphCache.keys, ...snapshot.keys]) {
          final match =
              RegExp(r'^(?:MangaType:|chapter_list_)(\d+)$').firstMatch(key);
          if (match != null) ids.add(int.parse(match[1]!));
        }
        final sortedIds = ids.toList()..sort();
        final existing = <int>{};
        for (var offset = 0; offset < sortedIds.length; offset += 100) {
          final batch =
              sortedIds.sublist(offset, min(offset + 100, sortedIds.length));
          final found = await client
              .query$ExistingLocalMangas(
                Options$Query$ExistingLocalMangas(
                  variables: Variables$Query$ExistingLocalMangas(ids: batch),
                  fetchPolicy: FetchPolicy.noCache,
                ),
              )
              .getData(
                  (data) => data.mangas.nodes.map((manga) => manga.id).toSet());
          if (found == null) {
            throw StateError('The server returned no manga lookup data');
          }
          if (!batch.toSet().containsAll(found)) {
            throw StateError('The server returned unexpected manga IDs');
          }
          existing.addAll(found);
        }
        final missing = ids.difference(existing);
        if (missing.isEmpty) return 0;
        await mutationCache.removeMangas(missing);
        await _clearQueryCache();
        return missing.length;
      });
}

final localCacheRepositoryProvider =
    Provider<LocalCacheRepository>((ref) => LocalCacheRepository(
          ref.watch(graphQlClientProvider),
          MutationCache(),
          clearImages: () async {
            await ref.read(mangaCacheManagerProvider).emptyCache();
            await LocalCacheRepository._clearImages();
          },
        ));
