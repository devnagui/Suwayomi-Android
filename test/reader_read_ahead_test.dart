import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/downloads/downloads_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads/downloads_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads_queue/downloads_queue_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/local_download_queue.dart';
import 'package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart';
import 'package:tachidesk_sorayomi/src/utils/network/reader_read_ahead.dart';

import 'chapter_download_regression_test.dart' show chapter, errorClient;
import 'download_diagnostics_test.dart' show download;

class _Server extends DownloadsRepository {
  _Server() : super(errorClient(), errorClient());
  final enqueued = <int>[];
  final completed = <int>{};
  final removed = <int>[];
  int? active;
  int? other;
  int ticks = 0;
  int failures = 0;
  bool paused = false;
  bool failResponseOnce = false;

  DownloadDto row(int id, String phase) {
    final json = download(state: phase, progress: .5).toJson();
    json['chapter']['id'] = id;
    json['manga']['id'] = 37;
    return DownloadDto.fromJson(json);
  }

  @override
  Future<DownloadStatusDto?> getDownloadStatus() async {
    if (active != null && ++ticks >= 2 && failures == 0) {
      completed.add(active!);
      active = null;
    }
    return DownloadStatusDto(
      state: paused || (active == null && other == null)
          ? DownloaderState.STOPPED
          : DownloaderState.STARTED,
      queue: [
        if (active != null)
          row(active!, failures > 0 ? 'ERROR' : 'DOWNLOADING'),
        if (other != null) row(other!, 'QUEUED'),
      ],
    );
  }

  @override
  Future<void> addChaptersBatchToDownloadQueue(List<int> ids) async {
    if (ids.length != 1 || active != null) {
      throw StateError('Read-ahead overlapped server jobs');
    }
    enqueued.add(ids.single);
    active = ids.single;
    ticks = 0;
    if (failResponseOnce) {
      failResponseOnce = false;
      throw StateError('Response lost after enqueue was accepted');
    }
  }

  @override
  Future<void> removeChapterFromDownloadQueue(int id) async {
    if (id != active) throw StateError('Removed an unrelated job');
    removed.add(id);
    active = null;
    if (failures > 0) failures--;
  }
}

class _Books extends MangaBookRepository {
  _Books(Ref ref, this.server, this.chapters) : super(errorClient(), ref);
  final _Server server;
  final List<ChapterDto> chapters;

  @override
  Future<List<ChapterDto>?> getChapterList(int mangaId) async => chapters;

  @override
  Future<ChapterDto?> getChapterFromServer({required int chapterId}) async {
    final value = chapters.firstWhere((c) => c.id == chapterId);
    return value.copyWith(
        user: value.user
            .copyWith(isDownloaded: server.completed.contains(chapterId)));
  }
}

class _Storage extends OfflineChapterManager {
  _Storage(super.ref);
  final available = <int>{};
  final excluded = <int>{};

  @override
  Future<bool> isAutomaticallyExcluded(int mangaId, int chapterId) async =>
      excluded.contains(chapterId);

  @override
  Future<bool> isChapterAvailableOffline(int mangaId, int chapterId) async =>
      available.contains(chapterId);
}

class _Copies extends LocalDownloadQueue {
  _Copies(this.storage);
  final _Storage storage;
  final started = <int>[];
  bool automaticCompletion = true;

  @override
  Map<int, LocalCacheState> build() => {};

  @override
  Future<void> enqueue(int mangaId, int chapterId,
      {bool automatic = false}) async {
    if (!automatic) {
      throw StateError('Automatic copy cleared manual exclusions');
    }
    started.add(chapterId);
    state = {
      ...state,
      chapterId: const LocalCacheState(LocalCacheStatus.caching, progress: .5)
    };
    if (automaticCompletion) complete(chapterId);
  }

  void complete(int chapterId) {
    storage.available.add(chapterId);
    state = {
      ...state,
      chapterId: const LocalCacheState(LocalCacheStatus.done, progress: 1)
    };
  }
}

Future<
    ({
      ProviderContainer container,
      _Server server,
      _Storage storage,
      _Copies copies
    })> harness({bool enabled = true}) async {
  SharedPreferences.setMockInitialValues({
    DBKeys.smartDownloadNextChapter.name: enabled,
  });
  final prefs = await SharedPreferences.getInstance();
  final server = _Server();
  late _Storage storage;
  late _Copies copies;
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    downloadUpdatesProvider.overrideWith((ref) => const Stream.empty()),
    downloadsRepositoryProvider.overrideWithValue(server),
    mangaBookRepositoryProvider.overrideWith((ref) =>
        _Books(ref, server, [for (var id = 84; id <= 90; id++) chapter(id)])),
    offlineChapterManagerProvider
        .overrideWith((ref) => storage = _Storage(ref)),
    localDownloadQueueProvider.overrideWith(() => copies = _Copies(storage)),
  ]);
  final storageSubscription =
      container.listen(offlineChapterManagerProvider, (_, __) {});
  addTearDown(storageSubscription.close);
  container.read(localDownloadQueueProvider);
  return (
    container: container,
    server: server,
    storage: storage,
    copies: copies
  );
}

Future<void> tick(WidgetTester tester, [int count = 1]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(seconds: 3));
  }
}

void main() {
  test('chapter84 selects85,86,87 independent of list direction/read state',
      () {
    final chapters = [
      for (var id = 90; id >= 80; id--) chapter(id, isRead: true)
    ];
    expect(
        selectReadAheadChapters(chapters, 84).map((c) => c.id), [85, 86, 87]);
    expect(selectReadAheadChapters(chapters, 90), isEmpty);
  });

  test('fractional chapters and duplicate groups preserve reading sequence',
      () {
    final current = chapter(84).copyWith(scanlator: 'chosen');
    final next = chapter(85).copyWith(scanlator: 'chosen');
    final duplicate = next.copyWith(id: 850, scanlator: 'other');
    final special = chapter(840).copyWith(chapterNumber: 84.5);
    expect(
        selectReadAheadChapters(
                [duplicate, chapter(86), next, current, special], 84)
            .map((c) => c.id),
        [840, 85, 86]);
  });

  test('unknown chapter numbers fall back to reverse source order', () {
    final chapters = [
      for (var id = 0; id < 5; id++)
        chapter(id).copyWith(chapterNumber: -1, sourceOrder: id)
    ];
    expect(selectReadAheadChapters(chapters, 4).map((c) => c.id), [3, 2, 1]);
  });

  testWidgets('server and device stages are serialized and deduplicated',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.copies.automaticCompletion = false;
    final service = h.container.read(readerReadAheadProvider.notifier);
    await service.request(37, 84);
    await tick(tester, 2);
    expect(h.server.enqueued, [85], reason: OperationLog.instance.exportJson());
    expect(h.copies.started, [85]);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.copying);
    await service.request(37, 84);
    await tick(tester, 2);
    expect(h.server.enqueued, [85]);
    h.copies.automaticCompletion = true;
    h.copies.complete(85);
    await tick(tester, 8);
    expect(h.server.enqueued, [85, 86, 87]);
    expect(h.copies.started, [85, 86, 87]);
    expect(
        h.container
            .read(readerReadAheadProvider)
            .values
            .every((s) => s.phase == ReadAheadPhase.ready),
        isTrue);
    await service.request(37, 85);
    await tick(tester, 4);
    expect(h.server.enqueued, [85, 86, 87, 88]);
  });

  testWidgets('disabled setting does not request server downloads',
      (tester) async {
    final h = await harness(enabled: false);
    addTearDown(h.container.dispose);
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, isEmpty);
    expect(h.container.read(readerReadAheadProvider), isEmpty);
  });

  testWidgets('cached chapters and manual exclusions do not re-download',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.storage.available.addAll([85, 87]);
    h.storage.excluded.add(86);
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, isEmpty);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.ready);
    expect(h.container.read(readerReadAheadProvider)[86]?.phase,
        ReadAheadPhase.cancelled);
  });

  testWidgets('paused unrelated queue is not resumed by auto enqueue',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.paused = true;
    h.server.other = 999;
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, isEmpty);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.paused);
    h.server.paused = false;
    h.server.other = null;
    await h.container.refresh(downloadStatusProvider.future);
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 86, 87]);
  });

  testWidgets('failure retries only its own chapter after backoff',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.failures = 1;
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, [85]);
    expect(h.server.removed, [85]);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.retrying);
    await tester.pump(const Duration(seconds: 29));
    expect(h.server.enqueued, [85]);
    await tester.pump(const Duration(seconds: 1));
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 85, 86, 87]);
  });

  testWidgets('three failures stop the window until an explicit retry',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.failures = 3;
    final service = h.container.read(readerReadAheadProvider.notifier);
    await service.request(37, 84);
    await tick(tester);
    await tester.pump(const Duration(seconds: 30));
    await tick(tester);
    await tester.pump(const Duration(seconds: 60));
    await tick(tester);
    expect(h.server.enqueued, [85, 85, 85]);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.failed);
    await tick(tester, 5);
    expect(h.server.enqueued, [85, 85, 85],
        reason: 'do not overload a failing source by advancing the window');
    service.retry(85);
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 85, 85, 85, 86, 87]);
  });

  testWidgets('server-cached chapters are copied without being re-enqueued',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.completed.addAll([85, 86, 87]);
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, isEmpty);
    expect(h.copies.started, [85, 86, 87]);
  });

  testWidgets('unrelated active work finishes before a read-ahead enqueue',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.other = 999;
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester, 2);
    expect(h.server.enqueued, isEmpty);
    h.server.other = null;
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 86, 87]);
  });

  testWidgets('lost enqueue response does not duplicate accepted work',
      (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    h.server.failResponseOnce = true;
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tick(tester);
    expect(h.server.enqueued, [85]);
    await tester.pump(const Duration(seconds: 30));
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 86, 87]);
  });

  testWidgets('manual dequeue is not automatically undone', (tester) async {
    final h = await harness();
    addTearDown(h.container.dispose);
    await h.container.read(readerReadAheadProvider.notifier).request(37, 84);
    await tester.pump();
    expect(h.server.enqueued, [85]);
    h.server.active = null;
    await tick(tester, 9);
    expect(h.server.enqueued, [85, 86, 87]);
    expect(h.container.read(readerReadAheadProvider)[85]?.phase,
        ReadAheadPhase.cancelled);
  });
}
