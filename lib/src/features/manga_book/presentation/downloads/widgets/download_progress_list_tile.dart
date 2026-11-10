// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../constants/app_sizes.dart';
import '../../../../../routes/router_config.dart';
import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../utils/logger/operation_log.dart';
import '../../../../../utils/misc/toast/toast.dart';
import '../../../../../widgets/async_buttons/async_icon_button.dart';
import '../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../../widgets/server_image.dart';
import '../../../data/downloads/downloads_repository.dart';
import '../../../domain/downloads/downloads_model.dart';
import '../controller/downloads_controller.dart';

class DownloadProgressListTile extends HookConsumerWidget {
  const DownloadProgressListTile({
    super.key,
    required this.chapterId,
    required this.toast,
    required this.index,
    required this.downloadsCount,
  });
  final int chapterId;
  final Toast? toast;
  final int index;
  final int downloadsCount;

  Future<void> toggleChapterToQueue(
    Toast? toast,
    WidgetRef ref,
    bool addToDownload,
    int chapterId,
  ) async {
    OperationLog.instance.record(
      'DownloadUiAction',
      outcome: 'triggered',
      action: addToDownload ? 'retry_queue_item' : 'remove_queue_item',
      chapterId: chapterId,
    );
    final result = await AsyncValue.guard(() async {
      final repo = ref.read(downloadsRepositoryProvider);
      await repo.removeChapterFromDownloadQueue(chapterId);
      if (addToDownload) {
        await repo.addChaptersBatchToDownloadQueue([chapterId]);
      }
    });
    result.showToastOnError(toast);
    if (!result.hasError) {
      await AsyncValue.guard(
        ref.read(downloadsMapProvider.notifier).refresh,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMutating = useState(false);
    final downloadUpdate = ref.watch(downloadsFromIdProvider(chapterId));
    if (downloadUpdate == null) return const SizedBox.shrink();

    Future<void> reorder(int position) async {
      if (isMutating.value) return;
      isMutating.value = true;
      try {
        final result = await AsyncValue.guard(
          () => ref
              .read(downloadsMapProvider.notifier)
              .reorder(downloadUpdate.chapter.id, position),
        );
        if (context.mounted) result.showToastOnError(toast);
      } finally {
        if (context.mounted) isMutating.value = false;
      }
    }

    Future<void> mutate(bool retry) async {
      if (isMutating.value) return;
      isMutating.value = true;
      try {
        await toggleChapterToQueue(
          toast,
          ref,
          retry,
          downloadUpdate.chapter.id,
        );
      } finally {
        if (context.mounted) isMutating.value = false;
      }
    }

    Future<void> confirmRemoval() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(dialogContext.l10n.delete),
          content: Text(downloadUpdate.chapter.name),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogContext.l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(dialogContext.l10n.delete),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) await mutate(false);
    }

    return Card(
      margin: KEdgeInsets.h16v4.size,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            if ((downloadUpdate.manga.thumbnailUrl).isNotBlank)
              Padding(
                padding: KEdgeInsets.a8.size,
                child: InkWell(
                  onTap: () => MangaRoute(mangaId: downloadUpdate.manga.id)
                      .push(context),
                  child: ClipRRect(
                    borderRadius: KBorderRadius.r8.radius,
                    child: ServerImage(
                      imageUrl: downloadUpdate.manga.thumbnailUrl!,
                      size: const Size.square(56),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: KEdgeInsets.a4.size,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        downloadUpdate.manga.title,
                        style: context.textTheme.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        downloadUpdate.chapter.name,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.labelSmall,
                      ),
                      trailing: Text(
                        downloadUpdate.toDisplayName(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    LinearProgressIndicator(
                      value: downloadUpdate.progress,
                      semanticsValue:
                          "${(downloadUpdate.progress * 100).toInt()}%",
                    ),
                    Row(
                      children: [
                        AsyncIconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              index.isZero ? null : () => reorder(index - 1),
                          icon: const Icon(Icons.arrow_drop_up_rounded),
                          color: Colors.grey,
                        ),
                        AsyncIconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: index >= downloadsCount - 1
                              ? null
                              : () => reorder(index + 1),
                          icon: const Icon(Icons.arrow_drop_down_rounded),
                          color: Colors.grey,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (isMutating.value)
              const MiniCircularProgressIndicator()
            else
              PopupMenuButton(
                shape: RoundedRectangleBorder(
                  borderRadius: KBorderRadius.r16.radius,
                ),
                itemBuilder: (context) => [
                  if (downloadUpdate.state == DownloadState.ERROR)
                    PopupMenuItem(
                      child: Text(context.l10n.retry),
                      onTap: () => mutate(true),
                    ),
                  PopupMenuItem(
                    onTap: confirmRemoval,
                    child: Text(context.l10n.delete),
                  ),
                  if (!index.isZero)
                    PopupMenuItem(
                      child: Text(context.l10n.moveToTop),
                      onTap: () => reorder(0),
                    ),
                  if (index < downloadsCount - 1)
                    PopupMenuItem(
                      child: Text(context.l10n.moveToBottom),
                      onTap: () => reorder(downloadsCount - 1),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
