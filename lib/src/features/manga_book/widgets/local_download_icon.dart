// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../utils/extensions/custom_extensions.dart';
import '../../../utils/misc/toast/toast.dart';
import '../../../utils/network/offline_chapter_manager.dart';
import '../data/manga_book/manga_book_repository.dart';
import '../domain/chapter/chapter_model.dart';

/// Icon button for downloading a chapter locally for offline reading.
class LocalDownloadIcon extends HookConsumerWidget {
  const LocalDownloadIcon({
    super.key,
    required this.chapter,
    required this.mangaId,
  });

  final ChapterDto chapter;
  final int mangaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(
      isChapterOfflineProvider(mangaId: mangaId, chapterId: chapter.id),
    );
    final isDownloading = useState(false);
    final progress = useState(0.0);

    return isOffline.when(
      data: (available) {
        if (available) {
          // Already downloaded locally
          return IconButton(
            icon: const Icon(
              Icons.download_done_rounded,
              color: Colors.green,
              size: 20,
            ),
            tooltip: 'Available offline',
            onPressed: () => _showDeleteDialog(context, ref),
          );
        }

        if (isDownloading.value) {
          return SizedBox(
            width: 40,
            height: 40,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: CircularProgressIndicator(
                value: progress.value > 0 ? progress.value : null,
                strokeWidth: 2,
              ),
            ),
          );
        }

        return IconButton(
          icon: const Icon(
            Icons.download_for_offline_outlined,
            size: 20,
          ),
          tooltip: 'Download for offline reading',
          onPressed: () =>
              _startDownload(context, ref, isDownloading, progress),
        );
      },
      loading: () => const SizedBox(width: 40, height: 40),
      error: (_, __) => const SizedBox(width: 40, height: 40),
    );
  }

  Future<void> _startDownload(
    BuildContext context,
    WidgetRef ref,
    ValueNotifier<bool> isDownloading,
    ValueNotifier<double> progress,
  ) async {
    final toast = ref.read(toastProvider);
    isDownloading.value = true;
    progress.value = 0;

    try {
      // First, fetch chapter pages from server
      final pagesDto = await ref
          .read(mangaBookRepositoryProvider)
          .getChapterPages(chapterId: chapter.id);

      if (pagesDto == null || pagesDto.pages.isEmpty) {
        toast?.show('Failed to get chapter pages');
        isDownloading.value = false;
        return;
      }

      // Start downloading
      final manager = ref.read(offlineChapterManagerProvider);
      await for (final status in manager.downloadChapter(
        mangaId: mangaId,
        chapterId: chapter.id,
        pageUrls: pagesDto.pages,
      )) {
        progress.value = status.progress;

        if (status.error != null) {
          toast?.show(status.error!);
          isDownloading.value = false;
          return;
        }

        if (status.isComplete) {
          toast?.show('Chapter downloaded for offline reading');
          // Invalidate the offline check provider
          ref.invalidate(
            isChapterOfflineProvider(mangaId: mangaId, chapterId: chapter.id),
          );
        }
      }
    } catch (e) {
      toast?.show('Download failed: $e');
    }

    isDownloading.value = false;
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove offline download?'),
        content: const Text(
            'This will delete the locally stored chapter. '
            'You can re-download it anytime.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(offlineChapterManagerProvider).deleteOfflineChapter(
                    mangaId,
                    chapter.id,
                  );
              ref.invalidate(
                isChapterOfflineProvider(
                    mangaId: mangaId, chapterId: chapter.id),
              );
              ref.read(toastProvider)?.show('Offline chapter removed');
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}
