import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/manga_book/data/downloads/downloads_repository.dart';
import '../../features/manga_book/data/manga_book/manga_book_repository.dart';
import '../../features/manga_book/domain/chapter/chapter_model.dart';
import '../../features/manga_book/domain/downloads/downloads_model.dart';
import '../../features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import '../../features/manga_book/presentation/manga_details/controller/manga_details_controller.dart';
import '../../features/settings/presentation/reader/widgets/reader_smart_download_tile/reader_smart_download_tile.dart';
import '../logger/operation_log.dart';
import 'local_download_queue.dart';
import 'offline_chapter_manager.dart';

const readerReadAheadCount = 3;

enum ReadAheadPhase {
  waiting,
  requesting,
  downloading,
  copying,
  retrying,
  paused,
  ready,
  failed,
  cancelled,
}

@immutable
class ReadAheadStatus {
  const ReadAheadStatus({
    required this.chapter,
    required this.phase,
    this.attempt = 0,
    this.reasonCode,
    this.progress,
  });

  final ChapterDto chapter;
  final ReadAheadPhase phase;
  final int attempt;
  final String? reasonCode;
  final double? progress;
}

List<ChapterDto> selectReadAheadChapters(
    List<ChapterDto> chapters, int currentId) {
  final currentIndex = chapters.indexWhere((c) => c.id == currentId);
  if (currentIndex < 0) return [];
  final current = chapters[currentIndex];
  final numbered = chapters.every((c) => c.chapterNumber >= 0) &&
      chapters.any((c) => c.chapterNumber != current.chapterNumber);
  final ordered = [...chapters]..sort((a, b) {
      if (numbered) {
        final number = a.chapterNumber.compareTo(b.chapterNumber);
        if (number != 0) return number;
        final preferredA = a.scanlator == current.scanlator;
        final preferredB = b.scanlator == current.scanlator;
        if (preferredA != preferredB) return preferredA ? -1 : 1;
      }
      return b.sourceOrder.compareTo(a.sourceOrder);
    });
  final next = numbered
      ? ordered.where((c) => c.chapterNumber > current.chapterNumber)
      : ordered.skip(ordered.indexWhere((c) => c.id == currentId) + 1);
  final seen = <double>{};
  return [
    for (final chapter in next)
      if (!numbered || seen.add(chapter.chapterNumber)) chapter,
  ].take(readerReadAheadCount).toList();
}

class _ReadAheadFailure implements Exception {
  const _ReadAheadFailure(this.reasonCode);
  final String reasonCode;
}

class _ReadAheadPaused implements Exception {}

class _ReadAheadCancelled implements Exception {}

/// Owns only one server-to-device read-ahead task, independent of reader routes.
class ReaderReadAhead extends Notifier<Map<int, ReadAheadStatus>> {
  final _pending = <ChapterDto>[];
  final _submitted = <int>{};
  final _accepted = <int>{};
  final _cancelled = <int>{};
  Future<void>? _running;
  (int, int)? _lastRequest;
  int? _active;
  bool _disposed = false;
  bool _paused = false;
  bool _blocked = false;
  Set<int> _windowIds = {};

  @override
  Map<int, ReadAheadStatus> build() {
    ref.onDispose(() => _disposed = true);
    ref.listen(offlineChapterManagerProvider, (_, __) {});
    ref.listen(smartDownloadNextChapterProvider, (_, enabled) {
      if (!enabled) {
        _lastRequest = null;
        for (final chapter in _pending) {
          _set(chapter, ReadAheadPhase.cancelled);
        }
        _pending.clear();
      }
    });
    ref.listen(downloadUpdatesProvider, (_, next) {
      if (next.valueOrNull?.state == DownloaderState.STARTED) _resume();
    });
    ref.listen(downloadStatusProvider, (_, next) {
      final status = next.valueOrNull;
      if (status != null &&
          (status.state == DownloaderState.STARTED || status.queue.isEmpty)) {
        _resume();
      }
    });
    return {};
  }

  Future<void> startReading(int mangaId, int chapterId) {
    _lastRequest = null;
    return request(mangaId, chapterId);
  }

  Future<void> request(int mangaId, int chapterId) async {
    if (_disposed || !ref.read(smartDownloadNextChapterProvider)) return;
    final key = (mangaId, chapterId);
    if (_lastRequest == key) return;
    _lastRequest = key;
    try {
      final provider = mangaChapterListProvider(mangaId: mangaId);
      var chapters = await ref.read(provider.future);
      if (chapters == null || !chapters.any((c) => c.id == chapterId)) {
        await ref.read(provider.notifier).refresh();
        chapters = ref.read(provider).valueOrNull;
      }
      if (_disposed ||
          _lastRequest != key ||
          !ref.read(smartDownloadNextChapterProvider)) {
        return;
      }
      if (chapters == null || !chapters.any((c) => c.id == chapterId)) {
        throw const _ReadAheadFailure('chapter_list_unavailable');
      }
      final next = selectReadAheadChapters(chapters, chapterId);
      final ids = next.map((c) => c.id).toSet();
      _windowIds = ids;
      _pending.clear();
      state = {
        for (final entry in state.entries)
          if (ids.contains(entry.key) || entry.key == _active)
            entry.key: entry.value,
      };
      // Entering another chapter starts a new bounded attempt window.
      // Keep owned work in flight, but do not retain an old failed-window lock.
      for (final entry in state.entries.toList()) {
        if (entry.value.phase == ReadAheadPhase.failed &&
            ids.contains(entry.key) &&
            entry.key != _active) {
          state = {...state}..remove(entry.key);
        }
      }
      _blocked = state.values.any((s) => s.phase == ReadAheadPhase.failed);
      for (final chapter in next) {
        if (_cancelled.contains(chapter.id) ||
            chapter.id == _active ||
            _pending.any((c) => c.id == chapter.id) ||
            state[chapter.id]?.phase == ReadAheadPhase.ready ||
            state[chapter.id]?.phase == ReadAheadPhase.failed) {
          continue;
        }
        _pending.add(chapter);
        _set(chapter, ReadAheadPhase.waiting);
      }
      _kick();
    } catch (error, stackTrace) {
      if (_disposed) return;
      _lastRequest = null;
      OperationLog.instance.record('ReaderReadAhead',
          outcome: 'failed',
          mangaId: mangaId,
          chapterId: chapterId,
          reasonCode: 'chapter_list_unavailable',
          error: error,
          stackTrace: stackTrace);
    }
  }

  void retry(int chapterId) {
    final status = state[chapterId];
    if (status == null || status.phase != ReadAheadPhase.failed) return;
    _cancelled.remove(chapterId);
    _pending.insert(0, status.chapter);
    _set(status.chapter, ReadAheadPhase.waiting);
    _paused = false;
    _blocked = false;
    _kick();
  }

  void _resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _kick();
  }

  void _kick() {
    if (_disposed ||
        _paused ||
        _blocked ||
        _running != null ||
        _pending.isEmpty ||
        !ref.read(smartDownloadNextChapterProvider)) {
      return;
    }
    _running = _drain().whenComplete(() {
      _running = null;
      _kick();
    });
  }

  Future<void> _drain() async {
    while (!_disposed &&
        _pending.isNotEmpty &&
        ref.read(smartDownloadNextChapterProvider)) {
      final chapter = _pending.removeAt(0);
      _active = chapter.id;
      try {
        await _prepare(chapter);
      } on _ReadAheadPaused {
        _pending.insert(0, chapter);
        _paused = true;
        break;
      } finally {
        _active = null;
      }
      if (_blocked) break;
    }
  }

  Future<void> _prepare(ChapterDto chapter) async {
    for (var attempt = 1; attempt <= 3 && !_disposed; attempt++) {
      try {
        await _downloadAndCopy(chapter, attempt);
        if (!_disposed) {
          _set(chapter, ReadAheadPhase.ready, attempt: attempt, progress: 1);
          OperationLog.instance.record('ReaderReadAhead',
              outcome: 'ready',
              mangaId: chapter.mangaId,
              chapterId: chapter.id,
              attempt: attempt);
        }
        return;
      } on _ReadAheadPaused {
        if (!_disposed) _set(chapter, ReadAheadPhase.paused, attempt: attempt);
        rethrow;
      } on _ReadAheadCancelled {
        _cancelled.add(chapter.id);
        if (!_disposed) {
          _set(chapter, ReadAheadPhase.cancelled, attempt: attempt);
        }
        return;
      } catch (error, stackTrace) {
        if (_disposed) return;
        if (!_windowIds.contains(chapter.id)) {
          state = {...state}..remove(chapter.id);
          return;
        }
        final reason =
            error is _ReadAheadFailure ? error.reasonCode : 'request_failed';
        OperationLog.instance.record('ReaderReadAhead',
            outcome: attempt == 3 ? 'failed' : 'retrying',
            mangaId: chapter.mangaId,
            chapterId: chapter.id,
            attempt: attempt,
            reasonCode: reason,
            error: error,
            stackTrace: stackTrace);
        _set(chapter,
            attempt == 3 ? ReadAheadPhase.failed : ReadAheadPhase.retrying,
            attempt: attempt, reasonCode: reason);
        if (attempt == 3) _blocked = true;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 30 * attempt));
        }
      }
    }
  }

  Future<void> _downloadAndCopy(ChapterDto chapter, int attempt) async {
    final manager = ref.read(offlineChapterManagerProvider);
    if (await manager.isAutomaticallyExcluded(chapter.mangaId, chapter.id)) {
      throw _ReadAheadCancelled();
    }
    if (await manager.isChapterAvailableOffline(chapter.mangaId, chapter.id)) {
      return;
    }
    final downloads = ref.read(downloadsRepositoryProvider);
    final books = ref.read(mangaBookRepositoryProvider);
    for (var poll = 0; poll < 100 && !_disposed; poll++) {
      if (await manager.isAutomaticallyExcluded(chapter.mangaId, chapter.id)) {
        throw _ReadAheadCancelled();
      }
      final status = await downloads.getDownloadStatus();
      if (_disposed) return;
      if (status == null) throw const _ReadAheadFailure('status_unavailable');
      final ownIndex =
          status.queue.indexWhere((d) => d.chapter.id == chapter.id);
      final own = ownIndex < 0 ? null : status.queue[ownIndex];
      if (own != null) _accepted.add(chapter.id);
      // Enqueue starts the global downloader: never resume unrelated paused work.
      if (status.state == DownloaderState.STOPPED &&
          status.queue.isNotEmpty &&
          !(status.queue.length == 1 &&
              own?.state == DownloadState.ERROR &&
              _submitted.contains(chapter.id))) {
        throw _ReadAheadPaused();
      }
      final fresh = await books.getChapterFromServer(chapterId: chapter.id);
      if (_disposed) return;
      if (fresh == null) throw const _ReadAheadFailure('chapter_unavailable');
      if (own?.state == DownloadState.ERROR) {
        if (_submitted.contains(chapter.id)) {
          await downloads.removeChapterFromDownloadQueue(chapter.id);
          _accepted.remove(chapter.id);
        }
        throw const _ReadAheadFailure('server_download_failed');
      }
      if (fresh.isDownloaded && own == null && status.queue.isEmpty) {
        _set(chapter, ReadAheadPhase.copying, attempt: attempt);
        await ref
            .read(localDownloadQueueProvider.notifier)
            .enqueue(chapter.mangaId, chapter.id, automatic: true);
        for (var copyPoll = 0; copyPoll < 100 && !_disposed; copyPoll++) {
          if (await manager.isAutomaticallyExcluded(
              chapter.mangaId, chapter.id)) {
            throw _ReadAheadCancelled();
          }
          final local = ref.read(localDownloadQueueProvider)[chapter.id];
          _set(chapter, ReadAheadPhase.copying,
              attempt: attempt, progress: local?.progress);
          if (local?.status == LocalCacheStatus.done &&
              await manager.isChapterAvailableOffline(
                  chapter.mangaId, chapter.id)) {
            return;
          }
          if (local?.status == LocalCacheStatus.failed) {
            throw const _ReadAheadFailure('device_copy_failed');
          }
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        throw const _ReadAheadFailure('device_copy_timeout');
      }
      if (own != null) {
        _set(chapter, ReadAheadPhase.downloading,
            attempt: attempt, progress: own.progress);
      } else if (!fresh.isDownloaded && _accepted.contains(chapter.id)) {
        throw _ReadAheadCancelled();
      } else if (status.queue.isEmpty && !fresh.isDownloaded) {
        final localBusy = ref.read(localDownloadQueueProvider).values.any(
              (task) =>
                  task.status == LocalCacheStatus.queued ||
                  task.status == LocalCacheStatus.caching,
            );
        if (localBusy) {
          _set(chapter, ReadAheadPhase.waiting, attempt: attempt);
        } else {
          _set(chapter, ReadAheadPhase.requesting, attempt: attempt);
          _submitted.add(chapter.id);
          await downloads.addChaptersBatchToDownloadQueue([chapter.id]);
          _accepted.add(chapter.id);
        }
      } else {
        _set(chapter, ReadAheadPhase.waiting, attempt: attempt);
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw const _ReadAheadFailure('server_wait_timeout');
  }

  void _set(ChapterDto chapter, ReadAheadPhase phase,
      {int attempt = 0, String? reasonCode, double? progress}) {
    if (_disposed) return;
    state = {
      ...state,
      chapter.id: ReadAheadStatus(
          chapter: chapter,
          phase: phase,
          attempt: attempt,
          reasonCode: reasonCode,
          progress: progress?.isFinite == true
              ? progress!.clamp(0.0, 1.0).toDouble()
              : null)
    };
  }
}

final readerReadAheadProvider =
    NotifierProvider<ReaderReadAhead, Map<int, ReadAheadStatus>>(
        ReaderReadAhead.new);
