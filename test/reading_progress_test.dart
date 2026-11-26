import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter_batch/chapter_batch_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/manga/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/manga/manga_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/manga_details/controller/manga_details_controller.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/graphql/__generated__/schema.graphql.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/reading_progress.dart';

import 'chapter_download_regression_test.dart' show chapter, errorClient;

final scope = StateProvider<String?>((ref) => 'account_A');

MangaDto manga(ChapterDto? last) => MangaDto(
    genre: [],
    id: 37,
    initialized: true,
    meta: [],
    sourceId: '1',
    status: Enum$MangaStatus.ONGOING,
    title: 'Manga',
    user: Fragment$MangaDto$user(
      inLibrary: true,
      inLibraryAt: '0',
      unreadCount: 10,
      downloadCount: 0,
      lastReadChapter: last,
    ),
    updateStrategy: Enum$UpdateStrategy.ALWAYS_UPDATE,
    url: '/manga/37');

class Books extends MangaBookRepository {
  Books(Ref ref) : super(errorClient(), ref);
  final chapters = {
    for (var id = 1; id <= 100; id++) id: chapter(id),
  };
  ChapterDto? latest;
  bool offline = false;
  bool loseResponse = false;
  bool wrongAck = false;
  Completer<void>? gate;
  final entered = Completer<void>();
  final writes = <({int id, ChapterChange patch})>[];
  int active = 0;
  int maxActive = 0;
  int serverAheadSeconds = 0;

  @override
  Future<MangaDto?> getMangaFromServer({required int mangaId}) async {
    if (offline) throw StateError('private-server-url');
    return manga(latest);
  }

  @override
  Future<MangaDto?> getManga({required int mangaId}) async => manga(latest);

  @override
  Future<List<ChapterDto>?> getChapterList(int mangaId) async =>
      chapters.values.toList();

  @override
  Future<ChapterDto?> getChapterFromServer({required int chapterId}) async {
    if (offline) throw StateError('private-server-url');
    return chapters[chapterId];
  }

  @override
  Future<ChapterDto?> putChapter(
      {required int chapterId, required ChapterChange patch}) async {
    if (offline) throw StateError('private-server-url');
    writes.add((id: chapterId, patch: patch));
    if (!entered.isCompleted) entered.complete();
    active++;
    if (active > maxActive) maxActive = active;
    await gate?.future;
    active--;
    final value = chapters[chapterId]!;
    final result = value.copyWith(
        user: value.user.copyWith(
      isRead: patch.isRead ?? value.isRead,
      lastPageRead: wrongAck ? 0 : patch.lastPageRead ?? value.lastPageRead,
      lastReadAt:
          '${DateTime.now().millisecondsSinceEpoch ~/ 1000 + serverAheadSeconds}',
    ));
    chapters[chapterId] = result;
    latest = result;
    if (loseResponse) {
      loseResponse = false;
      throw StateError('response lost');
    }
    return result;
  }
}

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    OperationLog.instance.clear();
  });

  ({ProviderContainer container, Books books}) harness() {
    late Books books;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      readingProgressScopeProvider.overrideWith((ref) => ref.watch(scope)),
      mangaBookRepositoryProvider.overrideWith((ref) => books = Books(ref)),
    ]);
    container.read(mangaBookRepositoryProvider);
    addTearDown(container.dispose);
    return (container: container, books: books);
  }

  test(
      'account identity is stable across token refresh and contains no credentials',
      () {
    String token(int id, String padding) =>
        '$padding.${base64Url.encode(utf8.encode(jsonEncode({
              'sub': '$id'
            })))}.signature';
    expect(readingAccount(AuthType.uiLogin, token(7, 'one'), null), 'user_7');
    expect(readingAccount(AuthType.uiLogin, token(7, 'two'), null), 'user_7');
    expect(readingAccount(AuthType.uiLogin, token(8, 'one'), null), 'user_8');
    expect(readingAccount(AuthType.uiLogin, 'invalid', null), isNull);
    final credentials =
        'Basic ${base64.encode(utf8.encode('reader:password'))}';
    expect(readingAccount(AuthType.basic, null, credentials), 'basic_reader');
  });

  test('first page and re-reading a completed chapter synchronize', () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84, isRead: true), 0, 10);
    await service.flush();
    expect(h.books.writes.single.id, 84);
    expect(h.books.writes.single.patch.lastPageRead, 0);
    expect(h.books.writes.single.patch.isRead, isTrue);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isFalse);
  });

  test('rapid exit flushes before debounce and records backwards movement',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 7, 10);
    await service.record(chapter(84), 3, 10);
    await service.flush();
    expect(h.books.writes, hasLength(1));
    expect(h.books.writes.single.patch.lastPageRead, 3);
    expect(service.startingPage(chapter(84)), 3);
  });

  test('finishing then moving backwards does not unmark the chapter as read',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 9, 10);
    await service.record(chapter(84), 4, 10);
    await service.flush();
    expect(h.books.writes.single.patch.lastPageRead, 4);
    expect(h.books.writes.single.patch.isRead, isTrue);
  });

  test('an inconsistent stored journal fails explicitly without rewriting it',
      () async {
    final bad = jsonEncode({
      '99': ReadingProgress(
        chapter: chapter(84),
        page: 2,
        pageCount: 10,
        readAtMs: 2000000000000,
        pending: true,
      ).toJson(),
    });
    await preferences.setString('reading_progress_v1_account_A', bad);
    final h = harness();
    expect(() => h.container.read(readingProgressProvider), throwsA(anything));
    expect(preferences.getString('reading_progress_v1_account_A'), bad);
    expect(OperationLog.instance.latestEvent('ReadingProgress')?['outcome'],
        'storage_invalid');
  });

  test('offline pending position survives a new Android session', () async {
    final h = harness();
    h.books.offline = true;
    var service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 5, 10);
    await service.flush();
    expect(h.books.writes, isEmpty);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isTrue);
    expect(OperationLog.instance.exportJson(),
        isNot(contains('private-server-url')));
    h.container.dispose();
    final restored = harness();
    service = restored.container.read(readingProgressProvider.notifier);
    expect(service.startingPage(chapter(84)), 5);
    await service.flush();
    expect(restored.books.writes.single.patch.lastPageRead, 5);
    expect(
        restored.container.read(readingProgressProvider)[37]?.pending, isFalse);
  });

  test('a later server reading wins over an old offline position', () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 4, 10);
    final local = h.container.read(readingProgressProvider)[37]!;
    h.books.latest = chapter(70).copyWith(
        user: chapter(70).user.copyWith(
              lastPageRead: 2,
              lastReadAt: '${local.readAtMs ~/ 1000 + 60}',
            ));
    await service.flush();
    expect(h.books.writes, isEmpty);
    expect(h.container.read(readingProgressProvider)[37]?.chapter.id, 70);
    expect(service.startingPage(h.books.latest!), 2);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isFalse);
  });

  test('offline chapters replay in reading-time order before latest resume',
      () async {
    final h = harness();
    h.books.serverAheadSeconds = 120;
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 9, 10);
    await service.record(chapter(85), 2, 10);
    await service.record(chapter(70), 4, 10);
    await service.flush();
    expect(h.books.writes.map((w) => w.id), [84, 85, 70]);
    expect(h.books.writes.first.patch.isRead, isTrue);
    expect(h.container.read(readingProgressProvider)[37]?.chapter.id, 70);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isFalse);
  });

  test('new page during an in-flight update is serialized and not cleared',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    h.books.gate = Completer<void>();
    await service.record(chapter(84), 2, 10);
    final sending = service.flush();
    await h.books.entered.future.timeout(const Duration(seconds: 3));
    await service.record(chapter(84), 6, 10);
    h.books.gate!.complete();
    await sending;
    expect(h.books.writes.map((w) => w.patch.lastPageRead), [2, 6]);
    expect(h.books.maxActive, 1);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isFalse);
  });

  test('an acknowledged server clock offset does not undo new local progress',
      () async {
    final h = harness();
    h.books.serverAheadSeconds = 300;
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 2, 10);
    await service.flush();
    await service.record(chapter(84), 4, 10);
    await service.flush();
    expect(h.books.writes.map((w) => w.patch.lastPageRead), [2, 4]);
  });

  test('changing accounts cannot submit another account pending progress',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 5, 10, expectedScope: 'account_A');
    h.container.read(scope.notifier).state = 'account_B';
    await h.container.pump();
    expect(h.container.read(readingProgressProvider), isEmpty);
    await service.flush();
    expect(h.books.writes, isEmpty);
    await expectLater(
        service.record(chapter(84), 7, 10, expectedScope: 'account_A'),
        throwsStateError);
    h.container.read(scope.notifier).state = 'account_A';
    await h.container.pump();
    expect(service.startingPage(chapter(84)), 5);
  });

  test('wrong mutation acknowledgement keeps progress pending', () async {
    final h = harness();
    h.books.wrongAck = true;
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 5, 10);
    await service.flush();
    expect(h.container.read(readingProgressProvider)[37]?.pending, isTrue);
    expect(OperationLog.instance.latestEvent('ReadingProgress')?['outcome'],
        'pending_retry');
  });

  test('explicit history removal cannot be resurrected by a delayed retry',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 6, 10);
    await service.discardChapters({84});
    await service.flush();
    expect(h.books.writes, isEmpty);
    expect(h.container.read(readingProgressProvider), isEmpty);
  });

  test(
      'Continue uses most recently read chapter, not the highest or first unread',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 3, 10);
    await service.record(chapter(70), 2, 10);
    final mangaProvider = mangaWithIdProvider(mangaId: 37);
    await h.container.read(mangaProvider.future);
    await h.container.read(mangaChapterListProvider(mangaId: 37).future);
    expect(h.container.read(mangaResumeChapterProvider(37))?.id, 70);
  });

  test('Continue follows newer server progress regardless of chapter filters',
      () async {
    final h = harness();
    h.books.latest = chapter(84, isRead: true).copyWith(
      user: chapter(84, isRead: true).user.copyWith(lastReadAt: '2000000000'),
    );
    await h.container.read(mangaWithIdProvider(mangaId: 37).future);
    await h.container.read(mangaChapterListProvider(mangaId: 37).future);
    h.container.read(mangaChapterFilterUnreadProvider.notifier).update(true);
    expect(h.container.read(mangaResumeChapterProvider(37))?.id, 84);
    expect(
        h.container.read(
            getNextAndPreviousChaptersProvider(mangaId: 37, chapterId: 999)),
        isNull);
  });

  test('latest position cannot be reused after chapter URL replacement',
      () async {
    final h = harness();
    final service = h.container.read(readingProgressProvider.notifier);
    await service.record(chapter(84), 6, 10);
    final replacement = chapter(84).copyWith(url: '/new');
    expect(service.startingPage(replacement), 0);
    h.books.chapters[84] = replacement;
    await service.flush();
    expect(h.books.writes, isEmpty);
    expect(h.container.read(readingProgressProvider)[37]?.pending, isTrue);
  });
}
