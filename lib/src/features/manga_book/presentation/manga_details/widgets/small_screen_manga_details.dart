// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../widgets/emoticons.dart';
import '../../../data/manga_book/manga_book_repository.dart';
import '../../../domain/chapter/chapter_model.dart';
import '../../../domain/manga/manga_model.dart';
import 'chapter_list_tile.dart';
import 'manga_description.dart';

class SmallScreenMangaDetails extends ConsumerStatefulWidget {
  const SmallScreenMangaDetails({
    super.key,
    required this.chapterList,
    required this.manga,
    required this.selectedChapters,
    required this.mangaId,
    required this.onRefresh,
    required this.onDescriptionRefresh,
    required this.onListRefresh,
  });
  final int mangaId;
  final MangaDto manga;
  final AsyncValueSetter<bool> onRefresh;
  final ValueNotifier<Map<int, ChapterDto>> selectedChapters;
  final AsyncValue<List<ChapterDto>?> chapterList;
  final AsyncValueSetter<bool> onListRefresh;
  final AsyncValueSetter<bool> onDescriptionRefresh;

  /// Number of chapters to show initially on Android for lazy loading
  static const int _initialChunkSize = 50;
  /// Number of chapters to load per "Load More" tap
  static const int _loadMoreChunkSize = 50;

  /// Whether lazy loading should be used (Android only, non-web)
  static bool get _useLazyLoad =>
      !kIsWeb && Platform.isAndroid;

  @override
  ConsumerState<SmallScreenMangaDetails> createState() =>
      _SmallScreenMangaDetailsState();
}

class _SmallScreenMangaDetailsState
    extends ConsumerState<SmallScreenMangaDetails> {
  int _visibleCount = SmallScreenMangaDetails._initialChunkSize;

  @override
  Widget build(BuildContext context) {
    final filteredChapterList = widget.chapterList.valueOrNull;
    final totalCount = filteredChapterList?.length ?? 0;

    // On Android, limit visible chapters; on other platforms show all
    final bool useLazy = SmallScreenMangaDetails._useLazyLoad &&
        totalCount > _visibleCount;
    final int displayCount = useLazy ? _visibleCount : totalCount;

    return RefreshIndicator(
      onRefresh: () => widget.onRefresh(true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              child: MangaDescription(
                manga: widget.manga,
                refresh: () => widget.onDescriptionRefresh(false),
                removeMangaFromLibrary: () => ref
                    .read(mangaBookRepositoryProvider)
                    .removeMangaFromLibrary(widget.mangaId),
                addMangaToLibrary: () => ref
                    .read(mangaBookRepositoryProvider)
                    .addMangaToLibrary(widget.mangaId),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: ListTile(
              title: Text(
                context.l10n.noOfChapters(totalCount),
              ),
            ),
          ),
          widget.chapterList.showUiWhenData(
            context,
            (data) {
              if (data.isNotBlank) {
                return SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      // "Load More" button at the end when lazy loading
                      if (useLazy && index == displayCount) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                          child: ElevatedButton.icon(
                            onPressed: () {
                              setState(() {
                                _visibleCount += SmallScreenMangaDetails
                                    ._loadMoreChunkSize;
                              });
                            },
                            icon: const Icon(Icons.expand_more),
                            label: Text(
                              'Carregar mais capítulos (${totalCount - displayCount} restantes)',
                            ),
                          ),
                        );
                      }
                      return ChapterListTile(
                        key: ValueKey("${filteredChapterList![index].id}"),
                        manga: widget.manga,
                        chapter: filteredChapterList[index],
                        updateData: () => widget.onRefresh(false),
                        isSelected: widget.selectedChapters.value
                            .containsKey(filteredChapterList[index].id),
                        canTapSelect:
                            widget.selectedChapters.value.isNotEmpty,
                        toggleSelect: (ChapterDto val) {
                          if ((val.id).isNull) return;
                          widget.selectedChapters.value = widget
                              .selectedChapters.value
                              .toggleKey(val.id, val);
                        },
                      );
                    },
                    childCount: useLazy ? displayCount + 1 : displayCount,
                  ),
                );
              } else {
                return SliverToBoxAdapter(
                  child: Emoticons(
                    title: context.l10n.noChaptersFound,
                    button: TextButton(
                      onPressed: () => widget.onDescriptionRefresh(true),
                      child: Text(context.l10n.refresh),
                    ),
                  ),
                );
              }
            },
            refresh: () => widget.onRefresh(false),
            wrapper: (child) => SliverToBoxAdapter(
              child: SizedBox(
                height: context.height * .5,
                child: child,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: ListTile()),
        ],
      ),
    );
  }
}
