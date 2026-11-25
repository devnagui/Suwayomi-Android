// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/manga_book/data/downloads/downloads_repository.dart';
import '../../features/manga_book/data/manga_book/manga_book_repository.dart';
import '../../features/manga_book/domain/downloads/downloads_model.dart';
import '../../features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import '../logger/operation_log.dart';
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
    this.alreadyCached = false,
  });

  final LocalCacheStatus status;
  final double progress;
  final int attempts;
  final bool alreadyCached;
}

enum _EnqueueResult { queued, inFlight, alreadyCached, excluded, failed }

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
  final _removed = <int>{};
  final _reportedExclusions = <(int, int, String)>{};
  final _availabilityChecks = <int, Completer<void>>{};
  Future<void>? _processing;
  Future<bool>? _reconciliation;
  Completer<void>? _activeCompletion;
  int? _activeChapterId;
  bool _disposed = false;
  bool _foreground = true;

  @override
  Map<int, LocalCacheState> build() {
    ref.onDispose(() => _disposed = true);
    // Auto-enqueue local caching whenever the server reports a finished
    // chapter download. The downloads map removes finished chapters, so we
    // observe the raw subscription here instead.
    ref.listen(downloadUpdatesProvider, (previous, next) {
      final updates = next.valueOrNull?.updates;
      // Initial messages also arrive after reconnect. Finished downloads are
      // absent from the live queue, so reconcile chapter metadata instead.
      if (next.valueOrNull?.initial != null) {
        unawaited(reconcile());
      }
      if (updates == null) return;
      for (final update in updates) {
        if (update.type == DownloadUpdateType.FINISHED) {
          unawaited(
            enqueue(
              update.download.manga.id,
              update.download.chapter.id,
              automatic: true,
            ),
          );
        }
      }
    });
    return const {};
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (foreground) unawaited(reconcile());
  }

  /// Catch up missed FINISHED events, including downloads made while closed.
  /// Fetch 25 metadata rows at a time and drain the existing serialized worker
  /// before adding another candidate; never create a second image downloader.
  Future<bool> reconcile() {
    if (_disposed || !_foreground) return Future.value(true);
    return _reconciliation ??=
        _reconcile().whenComplete(() => _reconciliation = null);
  }

  Future<bool> _reconcile() async {
    var candidates = 0;
    var copied = 0;
    var alreadyCached = 0;
    var excluded = 0;
    var failed = 0;
    try {
      final repository = ref.read(downloadsRepositoryProvider);
      String? after;
      final cursors = <String>{};
      do {
        final page = await repository.getOfflineCacheCandidates(after: after);
        if (_disposed || !_foreground) return true;
        if (page == null) {
          throw const LocalCacheException('candidate_query_failed');
        }
        for (final chapter in page.nodes) {
          if (_disposed || !_foreground) return true;
          candidates++;
          // Also check returned flags, rather than trusting a stale/misfiltered
          // server response to copy read chapters or non-library manga.
          if (!chapter.user.isDownloaded ||
              chapter.user.isRead ||
              !chapter.manga.user.inLibrary) {
            excluded++;
            _logExclusion(chapter.mangaId, chapter.id, 'cache_excluded');
            continue;
          }
          final result =
              await _enqueue(chapter.mangaId, chapter.id, automatic: true);
          // A concurrent enqueue may have reserved this chapter but still be
          // checking disk, before the serialized worker exists.
          await _availabilityChecks[chapter.id]?.future;
          while (!_disposed && _foreground) {
            final processing = _processing;
            if (processing == null) break;
            // Completion can start a replacement drain for a late enqueue.
            // Await that successor too before accounting or disposing a worker.
            await processing;
          }
          if (_disposed || !_foreground) return true;
          final cached = state[chapter.id];
          switch (result) {
            case _EnqueueResult.excluded:
              excluded++;
            case _EnqueueResult.alreadyCached:
              alreadyCached++;
            case _EnqueueResult.failed:
              failed++;
            case _EnqueueResult.queued:
            case _EnqueueResult.inFlight:
              if (_removed.contains(chapter.id)) {
                excluded++;
              } else if (cached?.status == LocalCacheStatus.done) {
                if (cached!.alreadyCached) {
                  alreadyCached++;
                } else {
                  copied++;
                }
              } else {
                failed++;
              }
          }
        }
        if (!page.pageInfo.hasNextPage) break;
        after = page.pageInfo.endCursor;
        if (after == null || !cursors.add(after)) {
          throw const LocalCacheException('pagination_stalled');
        }
      } while (!_disposed && _foreground);
      OperationLog.instance.record(
        'OfflineCacheCatchUp',
        stage: 'device_cache',
        outcome: failed > 0 ? 'failed' : 'completed',
        // Metadata candidates considered, not the number of downloads made.
        count: candidates,
        copied: copied,
        alreadyCached: alreadyCached,
        excluded: excluded,
        failed: failed,
      );
      return failed == 0;
    } catch (error, stackTrace) {
      if (!_disposed) {
        _logFailure('OfflineCacheCatchUp', error, stackTrace,
            count: candidates,
            copied: copied,
            alreadyCached: alreadyCached,
            excluded: excluded,
            failed: failed);
      }
      return false;
    }
  }

  /// Queue a chapter for local caching. No-op if it is already queued,
  /// caching, done, or already available offline.
  Future<void> enqueue(int mangaId, int chapterId,
      {bool automatic = false}) async {
    await _enqueue(mangaId, chapterId, automatic: automatic);
  }

  Future<_EnqueueResult> _enqueue(int mangaId, int chapterId,
      {bool automatic = false}) async {
    if (_disposed) return _EnqueueResult.excluded;
    if (automatic && _removed.contains(chapterId)) {
      _logExclusion(mangaId, chapterId, 'cache_removed');
      return _EnqueueResult.excluded;
    }
    Completer<void>? availabilityCheck;
    try {
      final manager = ref.read(offlineChapterManagerProvider);
      if (automatic) {
        if (await manager.isAutomaticallyExcluded(mangaId, chapterId)) {
          _logExclusion(mangaId, chapterId, 'cache_excluded');
          return _EnqueueResult.excluded;
        }
      } else {
        await manager.allowAutomaticCache(mangaId, chapterId);
      }
      if (_disposed || (automatic && _removed.contains(chapterId))) {
        return _EnqueueResult.excluded;
      }
      if (!automatic) {
        _removed.remove(chapterId);
        _reportedExclusions.removeWhere(
            (entry) => entry.$1 == mangaId && entry.$2 == chapterId);
      }
      final existing = state[chapterId];
      if (existing != null && existing.status != LocalCacheStatus.failed) {
        return existing.status == LocalCacheStatus.done
            ? _EnqueueResult.alreadyCached
            : _EnqueueResult.inFlight;
      }
      // Reserve before checking availability so simultaneous arrivals deduplicate.
      availabilityCheck = Completer<void>();
      _availabilityChecks[chapterId] = availabilityCheck;
      _set(chapterId, const LocalCacheState(LocalCacheStatus.queued));
      final available = await ref
          .read(offlineChapterManagerProvider)
          .isChapterAvailableOffline(mangaId, chapterId);
      if (_cancelled(chapterId)) return _EnqueueResult.excluded;
      if (available) {
        _set(chapterId,
            const LocalCacheState(LocalCacheStatus.done,
                progress: 1, alreadyCached: true));
        _logCache(mangaId, chapterId, 'already_on_device',
            reasonCode: 'already_on_device', progressPercent: 100);
        return _EnqueueResult.alreadyCached;
      }
      _queue.add(_LocalCacheTask(mangaId, chapterId));
      _logCache(mangaId, chapterId, 'queued', attempt: 1);
      unawaited(_process());
      return _EnqueueResult.queued;
    } catch (error, stackTrace) {
      if (_cancelled(chapterId)) return _EnqueueResult.excluded;
      _logFailure('OfflineChapterCache', error, stackTrace,
          mangaId: mangaId, chapterId: chapterId);
      _set(chapterId, const LocalCacheState(LocalCacheStatus.failed));
      return _EnqueueResult.failed;
    } finally {
      if (availabilityCheck != null) {
        if (identical(_availabilityChecks[chapterId], availabilityCheck)) {
          _availabilityChecks.remove(chapterId);
        }
        availabilityCheck.complete();
      }
    }
  }

  /// Manually retry caching a chapter (typically after a failure).
  void retry(int mangaId, int chapterId) {
    final status = state[chapterId]?.status;
    if (status == LocalCacheStatus.queued ||
        status == LocalCacheStatus.caching) {
      return;
    }
    _queue.removeWhere((task) => task.chapterId == chapterId);
    final next = {...state}..remove(chapterId);
    state = next;
    _logCache(mangaId, chapterId, 'retry', action: 'manual');
    unawaited(enqueue(mangaId, chapterId));
  }

  /// Stop an in-flight local copy before manual deletion removes its files.
  /// A stale catch-up page must not immediately undo that removal.
  Future<void> cancel(int chapterId) async {
    _removed.add(chapterId);
    _queue.removeWhere((task) => task.chapterId == chapterId);
    if (_activeChapterId == chapterId) {
      await _activeCompletion?.future;
    }
    if (!_disposed) state = {...state}..remove(chapterId);
  }

  bool _cancelled(int chapterId) => _disposed || _removed.contains(chapterId);

  Future<void> _process() => _processing ??= _drain().whenComplete(() {
        _processing = null;
        // A disk check can enqueue after the drain's final empty check but
        // before this completion callback. Do not strand that work.
        if (!_disposed && _queue.isNotEmpty) unawaited(_process());
      });

  Future<void> _drain() async {
    while (!_disposed && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      if (_cancelled(task.chapterId)) continue;
      _activeChapterId = task.chapterId;
      _activeCompletion = Completer<void>();
      try {
        await _runTask(task);
      } finally {
        _activeChapterId = null;
        _activeCompletion!.complete();
        _activeCompletion = null;
      }
    }
  }

  Future<void> _runTask(_LocalCacheTask task) async {
    _set(
      task.chapterId,
      LocalCacheState(LocalCacheStatus.caching, attempts: task.attempt),
    );
    _logCache(task.mangaId, task.chapterId, 'started',
        attempt: task.attempt + 1);

    try {
      final result = await _cache(task.mangaId, task.chapterId, (progress) {
        _set(
          task.chapterId,
          LocalCacheState(
            LocalCacheStatus.caching,
            progress: progress,
            attempts: task.attempt,
          ),
        );
      });
      if (_cancelled(task.chapterId)) return;
      _set(
        task.chapterId,
        LocalCacheState(LocalCacheStatus.done,
            progress: 1, alreadyCached: result?.alreadyCached ?? false),
      );
      _logCache(
        task.mangaId,
        task.chapterId,
        result?.alreadyCached == true ? 'already_on_device' : 'completed',
        attempt: task.attempt + 1,
        progressPercent: 100,
        completedPages: result?.downloadedPages,
        totalPages: result?.totalPages,
      );
      ref.invalidate(
        isChapterOfflineProvider(
          mangaId: task.mangaId,
          chapterId: task.chapterId,
        ),
      );
    } catch (error, stackTrace) {
      if (_cancelled(task.chapterId)) return;
      _logFailure('OfflineChapterCache', error, stackTrace,
          mangaId: task.mangaId,
          chapterId: task.chapterId,
          attempt: task.attempt + 1);
      if (task.attempt < _maxAutoRetries) {
        // Automatic retry with a short backoff.
        _set(
          task.chapterId,
          LocalCacheState(
            LocalCacheStatus.queued,
            attempts: task.attempt + 1,
          ),
        );
        _logCache(task.mangaId, task.chapterId, 'retry',
            attempt: task.attempt + 2, action: 'automatic');
        await Future<void>.delayed(const Duration(seconds: 2));
        if (_cancelled(task.chapterId)) return;
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
  }

  Future<LocalDownloadProgress?> _cache(
    int mangaId,
    int chapterId,
    ValueChanged<double> onProgress,
  ) async {
    final pagesDto = await ref
        .read(mangaBookRepositoryProvider)
        .getChapterPages(chapterId: chapterId);
    if (_cancelled(chapterId)) return null;
    if (pagesDto == null || pagesDto.pages.isEmpty) {
      throw const LocalCacheException('empty_pages', totalPages: 0);
    }

    final manager = ref.read(offlineChapterManagerProvider);
    LocalDownloadProgress? last;
    await for (final status in manager.downloadChapter(
      mangaId: mangaId,
      chapterId: chapterId,
      pageUrls: pagesDto.pages,
      logDiagnostics: false,
    )) {
      if (_cancelled(chapterId)) return null;
      last = status;
      onProgress(status.progress);
      if (status.error != null || status.cause != null) {
        throw LocalCacheException(
          status.reasonCode ?? 'cache_failure',
          cause: status.cause,
          stackTrace: status.stackTrace,
          httpStatus: status.httpStatus,
          completedPages: status.downloadedPages,
          totalPages: status.totalPages,
        );
      }
    }
    if (_cancelled(chapterId)) return null;
    if (!await manager.isChapterAvailableOffline(mangaId, chapterId)) {
      throw LocalCacheException('incomplete_copy',
          completedPages: last?.downloadedPages, totalPages: pagesDto.pages.length);
    }
    return last;
  }

  void _logFailure(String operation, Object error, StackTrace stackTrace,
      {int? mangaId,
      int? chapterId,
      int? attempt,
      int? count,
      int? copied,
      int? alreadyCached,
      int? excluded,
      int? failed}) {
    final failure = error is LocalCacheException ? error : null;
    OperationLog.instance.record(
      operation,
      outcome: 'failed',
      stage: 'device_cache',
      mangaId: mangaId,
      chapterId: chapterId,
      attempt: attempt,
      reasonCode: localCacheFailureReason(error),
      error: failure?.cause ?? error,
      stackTrace: failure?.stackTrace ?? stackTrace,
      httpStatus: failure?.httpStatus,
      completedPages: failure?.completedPages,
      totalPages: failure?.totalPages,
      count: count,
      copied: copied,
      alreadyCached: alreadyCached,
      excluded: excluded,
      failed: failed,
    );
  }

  void _logExclusion(int mangaId, int chapterId, String reasonCode) {
    if (_reportedExclusions.add((mangaId, chapterId, reasonCode))) {
      _logCache(mangaId, chapterId, 'excluded', reasonCode: reasonCode);
    }
  }

  void _logCache(int mangaId, int chapterId, String outcome,
      {int? attempt,
      int? progressPercent,
      int? completedPages,
      int? totalPages,
      String? reasonCode,
      String? action}) {
    OperationLog.instance.record(
      'OfflineChapterCache',
      stage: 'device_cache',
      outcome: outcome,
      mangaId: mangaId,
      chapterId: chapterId,
      attempt: attempt,
      progressPercent: progressPercent,
      completedPages: completedPages,
      totalPages: totalPages,
      reasonCode: reasonCode,
      action: action,
    );
  }

  void _set(int chapterId, LocalCacheState value) {
    if (!_disposed) {
      state = {...state, chapterId: value};
    }
  }
}

/// App-lifetime queue that caches finished server downloads onto the device.
final localDownloadQueueProvider =
    NotifierProvider<LocalDownloadQueue, Map<int, LocalCacheState>>(
  LocalDownloadQueue.new,
);
