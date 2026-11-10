// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../constants/app_sizes.dart';
import '../../../../constants/assets.dart';
import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/logger/operation_log.dart';
import '../../../../utils/misc/toast/toast.dart';
import '../../../../widgets/async_buttons/async_icon_button.dart';
import '../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../widgets/popup_widgets/pop_button.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../data/manga_book/manga_book_repository.dart';
import '../../domain/chapter/chapter_model.dart';
import '../../domain/chapter_batch/chapter_batch_model.dart';
import '../../presentation/downloads/controller/downloads_controller.dart';
import 'multi_chapters_action_icon.dart';

class MultiChaptersActionsBottomAppBar extends HookConsumerWidget {
  const MultiChaptersActionsBottomAppBar({
    super.key,
    required this.selectedChapters,
    required this.afterOptionSelected,
    required this.onChaptersUpdated,
    this.chapterList,
  });

  final ValueNotifier<Map<int, ChapterDto>> selectedChapters;
  final AsyncCallback afterOptionSelected;
  final AsyncValueSetter<List<ChapterDto>> onChaptersUpdated;
  final List<ChapterDto>? chapterList;

  List<int> get selectedChapterList => selectedChapters.value.keys.toList();
  ChapterDto get firstChapter =>
      selectedChapters.value[selectedChapterList.first]!;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    refresh([bool triggerAfterOption = true]) async {
      selectedChapters.value = {};
      if (triggerAfterOption) await afterOptionSelected();
    }

    Future<void> mergeUpdatedChapters(List<ChapterDto> chapters) async {
      await onChaptersUpdated(chapters);
      selectedChapters.value = {};
    }

    final selectedList = selectedChapters.value.values;
    final isDeleting = useState(false);

    Future<void> deleteDownloads() async {
      if (isDeleting.value) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.delete),
          content: Text(context.l10n.noOfChapters(selectedChapterList.length)),
          actions: [
            const PopButton(),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.delete),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;

      isDeleting.value = true;
      try {
        final result = await AsyncValue.guard(
          () => ref
              .read(mangaBookRepositoryProvider)
              .deleteChapters(selectedChapterList),
        );
        if (context.mounted) {
          result.showToastOnError(ref.read(toastProvider));
        }
        if (!result.hasError) await refresh(true);
      } finally {
        if (context.mounted) isDeleting.value = false;
      }
    }

    return Material(
      color: context.theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: KEdgeInsets.a8.size,
          child: Wrap(
            alignment: WrapAlignment.spaceEvenly,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (selectedList.any((e) => e.isBookmarked.ifNull()))
                MultiChaptersActionIcon(
                  iconData: Icons.bookmark_remove_rounded,
                  chapterList: selectedChapterList,
                  change: ChapterChange(isBookmarked: false),
                  onUpdated: mergeUpdatedChapters,
                ),
              if (selectedList.any((e) => !(e.isBookmarked.ifNull())))
                MultiChaptersActionIcon(
                  iconData: Icons.bookmark_add_rounded,
                  chapterList: selectedChapterList,
                  change: ChapterChange(isBookmarked: true),
                  onUpdated: mergeUpdatedChapters,
                ),
              if (selectedList.isSingletonList && chapterList.isNotBlank)
                MultiChaptersActionIcon(
                  chapterList: [
                    for (final chapter in chapterList!)
                      if (firstChapter.index > chapter.index) chapter.id
                  ],
                  icon: ImageIcon(
                    const AssetImage(AppAssets.previousDone),
                    color: context.theme.cardTheme.color,
                  ),
                  change: ChapterChange(isRead: true),
                  onUpdated: mergeUpdatedChapters,
                ),
              if (selectedList.any((e) => !(e.isRead.ifNull())))
                MultiChaptersActionIcon(
                  iconData: Icons.done_all_rounded,
                  chapterList: selectedChapterList,
                  change: ChapterChange(isRead: true, lastPageRead: 0),
                  onUpdated: mergeUpdatedChapters,
                ),
              if (selectedList.any((e) => e.isRead.ifNull()))
                MultiChaptersActionIcon(
                  iconData: Icons.remove_done_rounded,
                  chapterList: selectedChapterList,
                  change: ChapterChange(isRead: false),
                  onUpdated: mergeUpdatedChapters,
                ),
              if (selectedList.any((e) => !(e.isDownloaded.ifNull())))
                AsyncIconButton(
                  icon: Icon(Icons.download_rounded),
                  onPressed: () async {
                    final chapterIds = [
                      for (var chapter in selectedList)
                        if (!(chapter.isDownloaded.ifNull(true))) chapter.id,
                    ];
                    OperationLog.instance.record(
                      'DownloadUiAction',
                      outcome: 'triggered',
                      action: 'enqueue_selection',
                      count: chapterIds.length,
                    );
                    final result = await AsyncValue.guard(
                      () => ref
                          .read(downloadsRepositoryProvider)
                          .addChaptersBatchToDownloadQueue(chapterIds),
                    );
                    if (context.mounted) {
                      result.showToastOnError(ref.read(toastProvider));
                    }
                    if (!result.hasError) {
                      await AsyncValue.guard(
                        ref.read(downloadsMapProvider.notifier).refresh,
                      );
                      selectedChapters.value = {};
                    }
                  },
                ),
              if (selectedList.any((e) => e.isDownloaded.ifNull()))
                isDeleting.value
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: MiniCircularProgressIndicator(),
                      )
                    : IconButton(
                        icon: Icon(Icons.delete_rounded),
                        onPressed: deleteDownloads,
                      ),
            ],
          ),
        ),
      ),
    );
  }
}
