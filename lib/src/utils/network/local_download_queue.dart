// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/manga_book/data/manga_book/manga_book_repository.dart';
import '../../features/manga_book/domain/downloads/downloads_model.dart';
import '../../features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import 'offline_chapter_manager.dart';

/// Status of a chapter's local (on-device) caching task.
enum LocalCacheStatus { queued, caching, done, failed }

/// State of a single chapter's local caching task.
@immutable
class LocalCacheState {
  const LocalCacheState(
    this.status, {
    this.progress = 0,
    this.attempts = 0,
  });

  final LocalCacheStatus status;
  final double progress;
  final int attempts;
}

class _LocalCacheTask {
  const _LocalCacheTask(this.mangaId, this.chapterId, {this.attempt = 0});

  final int mangaId;
  final int chapterId;
  final int attempt;
}

/// Number of automatic retries before a task is marked as failed.
const _maxAutoRetries = 2;

/// App-scoped queue that caches chapter pages on the device for offline
/// reading once the server finishes downloading them.
///
/// This lives for the whole app lifetime (non-autoDispose), so caching keeps
/// running even after the originating chapter tile is scrolled away or the
/// user leaves the manga details page. Failed tasks are retried automatically
/// a few times and can also be retried manually via [retry].
class LocalDownloadQueue extends Notifier<Map<int, LocalCacheState>> {
  final _queue = <_LocalCacheTask>[];
  bool _processing = false;

  @override
  Map<int, LocalCacheState> build() {
    // Auto-enqueue local caching whenever the server reports a finished
    // chapter download. The downloads map removes finished chapters, so we
    // observe the raw subscription here instead.
    ref.listen(downloadUpdatesProvider, (previous, next) {
      final updates = next.valueOrNull?.updates;
      if (updates == null) return;
      for (final update in updates) {
        if (update.type == DownloadUpdateType.FINISHED) {
          enqueue(update.download.manga.id, update.download.chapter.id);
        }
      }
    });
    return const {};
  }

  /// Queue a chapter for local caching. No-op if it is already queued,
  /// caching, done, or already available offline.
  Future<void> enqueue(int mangaId, int chapterId) async {
    final existing = state[chapterId];
    if (existing != null && existing.status != LocalCacheStatus.failed) return;
    if (_queue.any((task) => task.chapterId == chapterId)) return;

    final available = await ref
        .read(offlineChapterManagerProvider)
        .isChapterAvailableOffline(mangaId, chapterId);
    if (available) {
      _set(chapterId, const LocalCacheState(LocalCacheStatus.done, progress: 1));
      return;
    }

    _queue.add(_LocalCacheTask(mangaId, chapterId));
    _set(chapterId, const LocalCacheState(LocalCacheStatus.queued));
    unawaited(_process());
  }

  /// Manually retry caching a chapter (typically after a failure).
  void retry(int mangaId, int chapterId) {
    _queue.removeWhere((task) => task.chapterId == chapterId);
    final next = {...state}..remove(chapterId);
    state = next;
    unawaited(enqueue(mangaId, chapterId));
  }

  Future<void> _process() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeAt(0);
        await _runTask(task);
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _runTask(_LocalCacheTask task) async {
    _set(
      task.chapterId,
      LocalCacheState(LocalCacheStatus.caching, attempts: task.attempt),
    );

    final ok = await _cache(task.mangaId, task.chapterId, (progress) {
      _set(
        task.chapterId,
        LocalCacheState(
          LocalCacheStatus.caching,
          progress: progress,
          attempts: task.attempt,
        ),
      );
    });

    if (ok) {
      _set(
        task.chapterId,
        const LocalCacheState(LocalCacheStatus.done, progress: 1),
      );
      ref.invalidate(
        isChapterOfflineProvider(
          mangaId: task.mangaId,
          chapterId: task.chapterId,
        ),
      );
    } else if (task.attempt < _maxAutoRetries) {
      // Automatic retry with a short backoff.
      _set(
        task.chapterId,
        LocalCacheState(
          LocalCacheStatus.queued,
          attempts: task.attempt + 1,
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      _queue.add(
        _LocalCacheTask(
          task.mangaId,
          task.chapterId,
          attempt: task.attempt + 1,
        ),
      );
    } else {
      _set(
        task.chapterId,
        LocalCacheState(LocalCacheStatus.failed, attempts: task.attempt),
      );
    }
  }

  Future<bool> _cache(
    int mangaId,
    int chapterId,
    ValueChanged<double> onProgress,
  ) async {
    try {
      final pagesDto = await ref
          .read(mangaBookRepositoryProvider)
          .getChapterPages(chapterId: chapterId);
      if (pagesDto == null || pagesDto.pages.isEmpty) return false;

      final manager = ref.read(offlineChapterManagerProvider);
      await for (final status in manager.downloadChapter(
        mangaId: mangaId,
        chapterId: chapterId,
        pageUrls: pagesDto.pages,
      )) {
        onProgress(status.progress);
        if (status.error != null) return false;
      }
      return manager.isChapterAvailableOffline(mangaId, chapterId);
    } catch (_) {
      return false;
    }
  }

  void _set(int chapterId, LocalCacheState value) {
    state = {...state, chapterId: value};
  }
}

/// App-lifetime queue that caches finished server downloads onto the device.
final localDownloadQueueProvider =
    NotifierProvider<LocalDownloadQueue, Map<int, LocalCacheState>>(
  LocalDownloadQueue.new,
);
