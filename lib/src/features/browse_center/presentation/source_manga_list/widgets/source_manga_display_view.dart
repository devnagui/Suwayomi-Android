// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

import '../../../../../constants/db_keys.dart';
import '../../../../../constants/enum.dart';
import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../utils/misc/toast/toast.dart';
import '../../../../manga_book/data/manga_book/manga_book_repository.dart';
import '../../../../manga_book/domain/manga/manga_model.dart';
import '../../../domain/source/source_model.dart';
import '../controller/source_manga_controller.dart';
import 'source_manga_grid_view.dart';
import 'source_manga_list_view.dart';

class SourceMangaDisplayView extends HookConsumerWidget {
  const SourceMangaDisplayView({
    super.key,
    required this.controller,
    required this.sourceId,
    required this.sourceType,
    this.source,
  });

  final PagingController<int, MangaDto> controller;
  final SourceDto? source;
  final String sourceId;
  final SourceType sourceType;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DisplayMode displayMode = ref.watch(sourceDisplayModeProvider) ??
        DBKeys.sourceDisplayMode.initial;
    final pendingMangaIds = useState(<int>{});
    toggleFavorite(MangaDto item) async {
      if (pendingMangaIds.value.contains(item.id)) return null;
      if (item.inLibrary.ifNull()) {
        bool removeManga = false;
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: item.title.isNotBlank ? Text(item.title) : null,
            content: Text(
              context.l10n.removeFromLibrary,
              style: context.textTheme.bodyLarge,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  removeManga = true;
                },
                child: Text(context.l10n.remove),
              ),
            ],
          ),
        );
        if (!removeManga) return null;
      }

      pendingMangaIds.value = {...pendingMangaIds.value, item.id};
      try {
        final result = await AsyncValue.guard(
          () => item.inLibrary.ifNull()
              ? ref
                  .read(mangaBookRepositoryProvider)
                  .removeMangaFromLibrary(item.id)
              : ref
                  .read(mangaBookRepositoryProvider)
                  .addMangaToLibrary(item.id),
        );
        if (context.mounted) {
          result.showToastOnError(ref.read(toastProvider));
        }
        return result;
      } finally {
        if (context.mounted) {
          pendingMangaIds.value = {...pendingMangaIds.value}..remove(item.id);
        }
      }
    }

    return switch (displayMode) {
      DisplayMode.grid => SourceMangaGridView(
          sourceId: sourceId,
          sourceType: sourceType,
          controller: controller,
          source: source,
          pendingMangaIds: pendingMangaIds.value,
          toggleFavorite: toggleFavorite,
        ),
      DisplayMode.list || DisplayMode.descriptiveList => SourceMangaListView(
          controller: controller,
          source: source,
          pendingMangaIds: pendingMangaIds.value,
          toggleFavorite: toggleFavorite,
        )
    };
  }
}
