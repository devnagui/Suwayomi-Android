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

  Future<List<ChapterDto>?> getChapterList(int mangaId) =>
      _loadChapterList(mangaId, () async {
        final chapters = <ChapterDto>[];
        String? after;
        do {
          final page = await client
              .query$GetChapterPage(
                Options$Query$GetChapterPage(
                  fetchPolicy: FetchPolicy.networkOnly,
                  variables: Variables$Query$GetChapterPage(
                    condition: Input$ChapterConditionInput(mangaId: mangaId),
                    first: 500,
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
        if (chapters.isEmpty) return await _fetchChapterList(mangaId);
        return chapters;
      });

  Future<List<ChapterDto>?> fetchChapterList(int mangaId) =>
      _loadChapterList(mangaId, () => _fetchChapterList(mangaId));

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
    Future<List<ChapterDto>?> Function() fetch,
  ) async {
    final cache = _cache ?? MutationCache();
    final cacheKey = 'chapter_list_$mangaId';
    Future<List<ChapterDto>?> fetchAndCache() async {
      final result = await fetch();
      if (result == null) {
        throw StateError('Chapter list returned no result');
      }
      await cache.put(cacheKey, result.map((c) => c.toJson()).toList());
      for (final chapter in result) {
        await cache.put('chapter_${chapter.id}', chapter.toJson());
      }
      OperationLog.instance.record('ChapterMetadataCache',
          outcome: 'processed',
          stage: 'metadata_cache',
          mangaId: mangaId,
          count: result.length);
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
        final cached = await cache.get(cacheKey);
        if (cached != null) {
          OperationLog.instance.record('MangaChapterList',
              outcome: 'offline_cache',
              mangaId: mangaId,
              count: (cached as List).length);
          return cached
              .map((e) => chapterFromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
      rethrow;
    }
  }
}

@riverpod
MangaBookRepository mangaBookRepository(Ref ref) =>
    MangaBookRepository(ref.watch(graphQlClientProvider), ref);
