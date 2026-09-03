// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../constants/app_sizes.dart';
import '../../../utils/extensions/custom_extensions.dart';
import '../../../utils/misc/toast/toast.dart';
import '../../../utils/network/local_download_queue.dart';
import '../../../utils/network/offline_chapter_manager.dart';
import '../../../widgets/custom_circular_progress_indicator.dart';
import '../data/downloads/downloads_repository.dart';
import '../data/manga_book/manga_book_repository.dart';
import '../domain/chapter/chapter_model.dart';
import '../domain/downloads/downloads_model.dart';
import '../presentation/downloads/controller/downloads_controller.dart';

class DownloadStatusIcon extends HookConsumerWidget {
  const DownloadStatusIcon({
    super.key,
    required this.updateData,
    required this.chapter,
    required this.mangaId,
    required this.isDownloaded,
  });
  final AsyncCallback updateData;
  final ChapterDto chapter;
  final int mangaId;
  final bool isDownloaded;

  Future<void> newUpdatePair(
      WidgetRef ref, ValueSetter<bool> setIsLoading) async {
    try {
      setIsLoading(true);
      await updateData();
      setIsLoading(false);
    } catch (e) {
      setIsLoading(false);
    }
  }

  /// Ask the user to confirm removing this chapter's download.
  Future<bool> _confirmRemove(BuildContext context) async {
    final l10n = context.l10n;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.delete),
        content: Text(chapter.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Remove both the server-side download and the on-device offline copy.
  Future<void> _removeDownload(WidgetRef ref, Toast? toast) async {
    (await AsyncValue.guard(
      () => ref.read(mangaBookRepositoryProvider).deleteChapters([chapter.id]),
    ))
        .showToastOnError(toast);
    await ref
        .read(offlineChapterManagerProvider)
        .deleteOfflineChapter(mangaId, chapter.id);
    ref.invalidate(
      isChapterOfflineProvider(mangaId: mangaId, chapterId: chapter.id),
    );
  }

  Future toggleChapterToQueue(
    Toast? toast,
    WidgetRef ref, {
    bool isAdd = false,
    bool isRemove = false,
    bool isError = false,
  }) async {
    try {
      final result = await AsyncValue.guard(() async {
        final repo = ref.read(downloadsRepositoryProvider);
        if (isRemove || isError) {
          await repo.removeChapterFromDownloadQueue(chapter.id);
        }
        if (isAdd || isError) {
          await repo.addChaptersBatchToDownloadQueue([chapter.id]);
          // Auto-start the downloader when enqueuing
          await repo.startDownloads();
        }
      });
      if (result.hasError) {
        toast?.showError('Erro ao iniciar download. Verifique a conexão.');
      }
    } catch (e) {
      toast?.showError('Erro ao iniciar download.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = useState(false);
    // Local state to track downloaded status after FINISHED
    final localIsDownloaded = useState(isDownloaded);
    // Optimistic state: show spinner immediately after enqueue tap
    final isEnqueuing = useState(false);

    // Whether the chapter pages are cached on this device for offline reading
    final offlineAvailable = ref
            .watch(isChapterOfflineProvider(
              mangaId: mangaId,
              chapterId: chapter.id,
            ))
            .valueOrNull ??
        false;

    // Watching the queue keeps it alive for the app lifetime, so local caching
    // keeps running (and retrying) even after this tile is scrolled away.
    final cacheState = ref.watch(
      localDownloadQueueProvider.select((map) => map[chapter.id]),
    );

    // Sync external prop changes
    useEffect(() {
      if (isDownloaded) {
        localIsDownloaded.value = true;
      }
      return null;
    }, [isDownloaded]);

    final toast = ref.watch(toastProvider);
    final downloadUpdate = ref.watch(downloadsFromIdProvider(chapter.id));

    // Clear optimistic state once the download shows up in the queue or the
    // local caching pipeline has picked it up.
    useEffect(() {
      if ((downloadUpdate != null || cacheState != null) &&
          isEnqueuing.value) {
        isEnqueuing.value = false;
      }
      return null;
    }, [downloadUpdate, cacheState]);

    // Best-effort UI refresh when this chapter finishes on the server. The
    // actual on-device caching (and its retries) is handled by the app-scoped
    // [localDownloadQueueProvider], so this only refreshes the tile.
    ref.listen(downloadUpdatesProvider, (previous, next) {
      final updates = next.valueOrNull?.updates;
      if (updates == null || updates.isEmpty) return;
      final justFinished = updates.any(
        (update) =>
            update.download.chapter.id == chapter.id &&
            update.type == DownloadUpdateType.FINISHED,
      );
      if (!justFinished) return;
      localIsDownloaded.value = true;
      isEnqueuing.value = false;
      Future.microtask(
        () => newUpdatePair(ref, (value) => isLoading.value = value),
      );
    });

    if (isLoading.value) {
      return Padding(
        padding: KEdgeInsets.h8.size,
        child: MiniCircularProgressIndicator(color: context.iconColor),
      );
    }

    // Server-side download in progress / queued / errored.
    if (downloadUpdate != null) {
      if (downloadUpdate.state == DownloadState.ERROR) {
        return IconButton(
          onPressed: () {
            isEnqueuing.value = true;
            toggleChapterToQueue(toast, ref, isError: true).then((_) {
              Future.delayed(const Duration(seconds: 8), () {
                if (isEnqueuing.value) isEnqueuing.value = false;
              });
            });
          },
          icon: const Icon(Icons.replay_rounded),
        );
      }
      return IconButton(
        onPressed: () => toggleChapterToQueue(toast, ref, isRemove: true),
        icon: MiniCircularProgressIndicator(
          value: downloadUpdate.progress == 0 ? null : downloadUpdate.progress,
          color: context.iconColor,
        ),
      );
    }

    // On-device caching queued after the server finished.
    if (cacheState != null) {
      switch (cacheState.status) {
        case LocalCacheStatus.queued:
          return Padding(
            padding: KEdgeInsets.h8.size,
            child: MiniCircularProgressIndicator(color: context.iconColor),
          );
        case LocalCacheStatus.caching:
          return Padding(
            padding: KEdgeInsets.h8.size,
            child: MiniCircularProgressIndicator(
              value: cacheState.progress > 0 ? cacheState.progress : null,
              color: context.iconColor,
            ),
          );
        case LocalCacheStatus.failed:
          return IconButton(
            tooltip: context.l10n.retry,
            icon: const Icon(Icons.error_outline_rounded, color: Colors.red),
            onPressed: () => ref
                .read(localDownloadQueueProvider.notifier)
                .retry(mangaId, chapter.id),
          );
        case LocalCacheStatus.done:
          break;
      }
    }

    // Cached on device for offline reading.
    if (offlineAvailable || cacheState?.status == LocalCacheStatus.done) {
      return IconButton(
        icon: const Icon(Icons.download_done_rounded, color: Colors.green),
        tooltip: 'Available offline',
        onPressed: () async {
          if (!await _confirmRemove(context)) return;
          await _removeDownload(ref, toast);
          localIsDownloaded.value = false;
          await newUpdatePair(ref, (value) => isLoading.value = value);
        },
      );
    }

    // Downloaded on the server but not yet cached on this device.
    if (localIsDownloaded.value) {
      return IconButton(
        icon: const Icon(Icons.check_circle_rounded),
        onPressed: () async {
          if (!await _confirmRemove(context)) return;
          await _removeDownload(ref, toast);
          localIsDownloaded.value = false;
          await newUpdatePair(ref, (value) => isLoading.value = value);
        },
      );
    }

    // Optimistic spinner right after the user taps download.
    if (isEnqueuing.value) {
      return Padding(
        padding: KEdgeInsets.h8.size,
        child: MiniCircularProgressIndicator(color: context.iconColor),
      );
    }

    // Nothing downloaded yet — offer to enqueue a server download.
    return IconButton(
      icon: const Icon(Icons.download_for_offline_rounded),
      onPressed: () {
        isEnqueuing.value = true;
        toggleChapterToQueue(toast, ref, isAdd: true).then((_) {
          Future.delayed(const Duration(seconds: 8), () {
            if (isEnqueuing.value) isEnqueuing.value = false;
          });
        });
      },
    );
  }
}
