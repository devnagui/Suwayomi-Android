// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../global_providers/global_providers.dart';
import '../../../../graphql/__generated__/schema.graphql.dart';
import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/logger/operation_log.dart';
import '../../../../utils/network/auth_token_refresh.dart';
import '../../../../utils/network/mutation_cache.dart';
import '../../../library/domain/category/category_model.dart';
import '../../domain/chapter/chapter_model.dart';
import '../../domain/chapter/graphql/__generated__/fragment.graphql.dart';
import '../../domain/chapter_batch/chapter_batch_model.dart';
import '../../domain/chapter_page/chapter_page_model.dart';
import '../../domain/manga/manga_model.dart';
import './__generated__/query.graphql.dart';

part 'manga_book_repository.g.dart';

class MangaBookRepository {
  const MangaBookRepository(
    this.client,
    this.ref, {
    this.cacheChapterPages = true,
    MutationCache? cache,
  }) : _cache = cache;
  final GraphQLClient client;
  final Ref ref;
  final bool cacheChapterPages;
  final MutationCache? _cache;

  Future<MangaDto?> addMangaToLibrary(int mangaId) => client
      .mutate$UpdateManga(
        Options$Mutation$UpdateManga(
          variables: Variables$Mutation$UpdateManga(
            input: Input$UpdateMangaInput(
              id: mangaId,
              patch: Input$UpdateMangaPatchInput(inLibrary: true),
            ),
          ),
        ),
      )
      .getData((data) => data.updateManga?.manga);

  Future<void> removeMangaFromLibrary(int mangaId) => client
      .mutate$UpdateManga(
        Options$Mutation$UpdateManga(
          variables: Variables$Mutation$UpdateManga(
            input: Input$UpdateMangaInput(
              id: mangaId,
              patch: Input$UpdateMangaPatchInput(inLibrary: false),
            ),
          ),
        ),
      )
      .getData((data) => data.updateManga?.manga);

  Future<List<ChapterDto>?> modifyBulkChapters(ChapterBatch batch) => client
      .mutate$UpdateChapters(
        Options$Mutation$UpdateChapters(
          variables: Variables$Mutation$UpdateChapters(input: batch),
        ),
      )
      .getData((data) => data.updateChapters?.chapters);

  Future<void> deleteChapters(List<int> chapterIds) => client
      .mutate$DeleteDownloadedChapters(
        Options$Mutation$DeleteDownloadedChapters(
          variables: Variables$Mutation$DeleteDownloadedChapters(
            input: Input$DeleteDownloadedChaptersInput(ids: chapterIds),
          ),
        ),
      )
      .getData<void>((_) {});

  // Mangas
  Future<MangaDto?> getManga({
    required int mangaId,
  }) =>
      networkFirstQuery(
        (policy) => client.query$GetManga(Options$Query$GetManga(
          variables: Variables$Query$GetManga(id: mangaId),
          fetchPolicy: policy,
        )),
      ).getData((data) => data.manga);

  Future<List<CategoryDto>?> getMangaCategoryList({
    required int mangaId,
  }) async =>
      client
          .query$GetMangaCategories(
            Options$Query$GetMangaCategories(
              variables: Variables$Query$GetMangaCategories(id: mangaId),
            ),
          )
          .getData((data) => data.manga.categories.nodes);

  Future<void> addMangaToCategory(int mangaId, int categoryId) =>
      client.mutate$UpdateMangaCategories(
        Options$Mutation$UpdateMangaCategories(
          variables: Variables$Mutation$UpdateMangaCategories(
            updateCategoryInput: Input$UpdateMangaCategoriesInput(
              id: mangaId,
              patch: Input$UpdateMangaCategoriesPatchInput(
                addToCategories: [categoryId],
              ),
            ),
          ),
        ),
      );

  Future<void> removeMangaFromCategory(int mangaId, int categoryId) =>
      client.mutate$UpdateMangaCategories(
        Options$Mutation$UpdateMangaCategories(
          variables: Variables$Mutation$UpdateMangaCategories(
            updateCategoryInput: Input$UpdateMangaCategoriesInput(
              id: mangaId,
              patch: Input$UpdateMangaCategoriesPatchInput(
                removeFromCategories: [categoryId],
              ),
            ),
          ),
        ),
      );

  // Chapters

  Future<ChapterDto?> getChapter({
    required int chapterId,
  }) async {
    final cache = MutationCache();
    final cacheKey = 'chapter_$chapterId';
    try {
      final result = await client
          .query$GetChapter(
            Options$Query$GetChapter(
              variables: Variables$Query$GetChapter(
                id: chapterId,
              ),
            ),
          )
          .getData((data) => data.chapter);
      if (result != null) {
        await cache.put(cacheKey, result.toJson());
      }

      return result;
    } catch (_) {
      final cached = await cache.get(cacheKey);
      if (cached != null) {
        return chapterFromJson(cached as Map<String, dynamic>);
      }
      rethrow;
    }
  }

  Future<ChapterDto?> getChapterFromServer({required int chapterId}) => client
      .query$GetChapter(Options$Query$GetChapter(
        operationName: 'GetChapter',
        fetchPolicy: FetchPolicy.networkOnly,
        variables: Variables$Query$GetChapter(id: chapterId),
      ))
      .getData((data) => data.chapter);

  Future<ChapterPagesDto?> getChapterPages({
    required int chapterId,
  }) async {
    final cache = MutationCache();
    final cacheKey = 'chapter_pages_$chapterId';
    try {
      final result = await client
          .mutate$GetChapterPages(
            Options$Mutation$GetChapterPages(
              variables: Variables$Mutation$GetChapterPages(
                  input: Input$FetchChapterPagesInput(chapterId: chapterId)),
            ),
          )
          .getData((data) => data.fetchChapterPages);
      if (result != null && cacheChapterPages) {
        await cache.put(cacheKey, result.toJson());
      }
      return result;
    } catch (_) {
      if (!cacheChapterPages) rethrow;
      // Offline fallback
      final cached = await cache.get(cacheKey);
      if (cached != null) {
        return ChapterPagesDto.fromJson(cached as Map<String, dynamic>);
      }
      rethrow;
    }
  }

  Future<ChapterDto?> putChapter({
    required int chapterId,
    required ChapterChange patch,
  }) =>
      client
          .mutate$UpdateChapter(
            Options$Mutation$UpdateChapter(
              variables: Variables$Mutation$UpdateChapter(
                input: Input$UpdateChapterInput(
                  id: chapterId,
                  patch: patch,
                ),
              ),
            ),
          )
          .getData((data) => data.updateChapter?.chapter);

  Future<void> patchMangaMeta({
    required int mangaId,
    required String key,
    required dynamic value,
  }) async =>
      client.mutate$SetMangaMeta(
        Options$Mutation$SetMangaMeta(
          variables: Variables$Mutation$SetMangaMeta(
            input: Input$SetMangaMetaInput(
              meta: Input$MangaMetaTypeInput(
                key: key,
                mangaId: mangaId,
                value: value,
              ),
            ),
          ),
        ),
      );

  Future<List<ChapterDto>?> getChapterList(int mangaId) => _loadChapterList(
      mangaId,
      (cached) => cached.isEmpty
          ? _fetchStoredChapterList(mangaId, initialize: true)
          : _fetchIncrementalChapterList(mangaId, cached));

  Future<List<ChapterDto>?> _fetchStoredChapterList(
    int mangaId, {
    List<int>? ids,
    bool initialize = false,
  }) async {
    final chapters = <ChapterDto>[];
    String? after;
    do {
      final page = await client
          .query$GetChapterPage(
            Options$Query$GetChapterPage(
              operationName: 'GetChapterPage',
              fetchPolicy: FetchPolicy.networkOnly,
              variables: Variables$Query$GetChapterPage(
                condition: Input$ChapterConditionInput(mangaId: mangaId),
                filter: ids == null
                    ? null
                    : Input$ChapterFilterInput(
                        id: Input$IntFilterInput($in: ids)),
                first: ids?.length ?? 500,
                after: after,
                order: [
                  Input$ChapterOrderInput(
                    by: Enum$ChapterOrderBy.SOURCE_ORDER,
                    byType: Enum$SortOrder.ASC,
                  ),
                ],
              ),
            ),
          )
          .getData((data) => data.chapters);
      if (page == null) {
        throw StateError('Chapter list returned no result');
      }
      chapters.addAll(page.nodes);
      if (!page.pageInfo.hasNextPage) break;
      final next = page.pageInfo.endCursor;
      if (next == null || next == after) {
        throw StateError('Chapter list returned an invalid cursor');
      }
      after = next;
    } while (true);
    // New manga have no stored chapters until their first source fetch.
    if (initialize && chapters.isEmpty) {
      return await _fetchChapterList(mangaId);
    }
    return chapters;
  }

  Future<List<ChapterDto>> _fetchIncrementalChapterList(
    int mangaId,
    Map<int, ChapterDto> cached,
  ) async {
    final index = <int, Query$GetChapterIndex$chapters$nodes>{};
    String? after;
    int? totalCount;
    do {
      final page = await client
          .query$GetChapterIndex(Options$Query$GetChapterIndex(
            operationName: 'GetChapterIndex',
            fetchPolicy: FetchPolicy.networkOnly,
            variables:
                Variables$Query$GetChapterIndex(mangaId: mangaId, after: after),
          ))
          .getData((data) => data.chapters);
      if (page == null) throw StateError('Chapter index returned no result');
      totalCount ??= page.totalCount;
      if (totalCount != page.totalCount) {
        throw StateError('Server chapters changed during refresh; retry');
      }
      for (final entry in page.nodes) {
        if (entry.mangaId != mangaId || index.containsKey(entry.id)) {
          throw StateError('Chapter index contains inconsistent entries');
        }
        index[entry.id] = entry;
      }
      if (!page.pageInfo.hasNextPage) break;
      final next = page.pageInfo.endCursor;
      if (next == null || next == after) {
        throw StateError('Chapter index returned an invalid cursor');
      }
      after = next;
    } while (true);
    if (index.length != totalCount) {
      throw StateError('Chapter index returned an incomplete list');
    }

    final missing = [
      for (final entry in index.values)
        if (cached[entry.id]?.url != entry.url) entry.id,
    ];
    final details = <int, ChapterDto>{};
    for (var offset = 0; offset < missing.length; offset += 100) {
      final batch = missing.skip(offset).take(100).toList();
      final chapters = await _fetchStoredChapterList(mangaId, ids: batch);
      if (chapters == null) {
        throw StateError('Chapter details returned no result');
      }
      final received = <int>{};
      for (final chapter in chapters) {
        if (chapter.mangaId != mangaId ||
            !batch.contains(chapter.id) ||
            !received.add(chapter.id)) {
          throw StateError('Chapter details contain inconsistent entries');
        }
        details[chapter.id] = chapter;
      }
      if (received.length != batch.length) {
        throw StateError('Server chapters changed during refresh; retry');
      }
    }

    final result = <ChapterDto>[
      for (final entry in index.values)
        details[entry.id] ??
            cached[entry.id]!.copyWith(
              sourceOrder: entry.sourceOrder,
              pageCount: entry.pageCount,
              user: cached[entry.id]!.user.copyWith(
                    isBookmarked: entry.user.isBookmarked,
                    isDownloaded: entry.user.isDownloaded,
                    isRead: entry.user.isRead,
                    lastPageRead: entry.user.lastPageRead,
                    lastReadAt: entry.user.lastReadAt,
                  ),
            ),
    ]..sort((a, b) {
        final order = a.sourceOrder.compareTo(b.sourceOrder);
        return order != 0 ? order : a.id.compareTo(b.id);
      });
    OperationLog.instance.record('MangaChapterSync',
        outcome: 'details_fetched',
        stage: 'metadata_cache',
        mangaId: mangaId,
        count: missing.length,
        alreadyCached: index.length - missing.length);
    return result;
  }

  Future<List<ChapterDto>?> fetchChapterList(int mangaId) =>
      _loadChapterList(mangaId, (_) => _fetchChapterList(mangaId),
          overwriteMetadata: true);

  Future<List<ChapterDto>?> _fetchChapterList(int mangaId) => client
      .mutate$GetChaptersByMangaId(
        Options$Mutation$GetChaptersByMangaId(
          variables: Variables$Mutation$GetChaptersByMangaId(
            input: Input$FetchMangaAndChaptersInput(
              id: mangaId,
              fetchManga: false,
              fetchChapters: true,
            ),
          ),
        ),
      )
      .getData((data) => data.fetchChapters?.chapters);

  Future<List<ChapterDto>?> _loadChapterList(
    int mangaId,
    Future<List<ChapterDto>?> Function(Map<int, ChapterDto> cached) fetch, {
    bool overwriteMetadata = false,
  }) async {
    final cache = _cache ?? MutationCache();
    final cacheKey = 'chapter_list_$mangaId';
    final cached = await _readCachedChapterMap(cache, mangaId);
    Future<List<ChapterDto>?> fetchAndCache() async {
      final result = await fetch(cached);
      if (result == null) {
        throw StateError('Chapter list returned no result');
      }
      final changed = [
        for (final chapter in result)
          if (overwriteMetadata || cached[chapter.id] != chapter) chapter,
      ];
      if (overwriteMetadata ||
          changed.isNotEmpty ||
          cached.length != result.length) {
        await cache.put(cacheKey, result.map((c) => c.toJson()).toList());
      }
      for (final chapter in changed) {
        await cache.put('chapter_${chapter.id}', chapter.toJson());
      }
      OperationLog.instance.record('ChapterMetadataCache',
          outcome: changed.isEmpty ? 'unchanged' : 'processed',
          stage: 'metadata_cache',
          mangaId: mangaId,
          count: changed.length);
      OperationLog.instance.record('MangaChapterList',
          outcome: 'server', mangaId: mangaId, count: result.length);
      return result;
    }

    try {
      try {
        return await fetchAndCache();
      } on OperationMessageException catch (error) {
        final didRefresh = await refreshUiLoginToken(
          ref: ref,
          client: client,
          exception: error.exception,
        );
        if (!didRefresh) rethrow;
        return await fetchAndCache();
      }
    } on OperationMessageException catch (error) {
      final exception = error.exception;
      if (exception.graphqlErrors.isEmpty &&
          (exception.linkException is NetworkException ||
              exception.linkException?.originalException is TimeoutException)) {
        final fallback = await _readCachedChapterMap(cache, mangaId);
        if (fallback.isNotEmpty) {
          OperationLog.instance.record('MangaChapterList',
              outcome: 'offline_cache',
              mangaId: mangaId,
              count: fallback.length);
          return fallback.values.toList();
        }
      }
      rethrow;
    }
  }

  Future<Map<int, ChapterDto>> _readCachedChapterMap(
      MutationCache cache, int mangaId) async {
    final json = await cache.get('chapter_list_$mangaId');
    if (json == null) return {};
    try {
      if (json is! List) throw const FormatException('Invalid chapter cache');
      final chapters = <int, ChapterDto>{};
      for (final entry in json) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('Invalid cached chapter');
        }
        final chapter = chapterFromJson(entry);
        if (chapter.mangaId != mangaId || chapters.containsKey(chapter.id)) {
          throw const FormatException('Inconsistent cached chapter');
        }
        chapters[chapter.id] = chapter;
      }
      return chapters;
    } on FormatException catch (error, stackTrace) {
      OperationLog.instance.record('MangaChapterSync',
          outcome: 'cache_invalid',
          mangaId: mangaId,
          error: error,
          stackTrace: stackTrace);
      return {};
    } on TypeError catch (error, stackTrace) {
      OperationLog.instance.record('MangaChapterSync',
          outcome: 'cache_invalid',
          mangaId: mangaId,
          error: error,
          stackTrace: stackTrace);
      return {};
    }
  }
}

@riverpod
MangaBookRepository mangaBookRepository(Ref ref) =>
    MangaBookRepository(ref.watch(graphQlClientProvider), ref);
