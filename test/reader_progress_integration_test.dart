import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter_page/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/controller/reader_controller.dart'
    show chapterProvider, chapterPagesProvider;
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/offline_reader_provider.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/reader_screen.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/utils/network/reader_read_ahead.dart';
import 'package:tachidesk_sorayomi/src/utils/network/reading_progress.dart';

import 'chapter_download_regression_test.dart' show chapter;
import 'reading_progress_test.dart' show Books;

class RecordingReadAhead extends ReaderReadAhead {
  final requests = <(int, int)>[];

  @override
  Map<int, ReadAheadStatus> build() => {};

  @override
  Future<void> request(int mangaId, int chapterId) async {
    requests.add((mangaId, chapterId));
  }
}

void main() {
  for (final mode
      in ReaderMode.values.where((m) => m != ReaderMode.defaultReader)) {
    testWidgets(
        '$mode replenishes read-ahead on entry and every chapter transition',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        DBKeys.readerMode.name: mode.index,
        DBKeys.smartDownloadNextChapter.name: true,
        DBKeys.readerOverlay.name: false,
      });
      final preferences = await SharedPreferences.getInstance();
      final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('reader-progress-')))!;
      addTearDown(
          () => tester.runAsync(() => directory.delete(recursive: true)));
      final files = await tester.runAsync(() async {
        final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==');
        return [
          for (var i = 0; i < 3; i++)
            await File('${directory.path}${Platform.pathSeparator}$i.png')
                .writeAsBytes(bytes),
        ];
      });
      late Books books;
      final readAhead = RecordingReadAhead();
      final nextPages = Completer<void>();
      final selectedChapter = ValueNotifier(84);
      addTearDown(selectedChapter.dispose);
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        readingProgressScopeProvider.overrideWithValue('reader_test'),
        mangaBookRepositoryProvider.overrideWith((ref) => books = Books(ref)),
        readerReadAheadProvider.overrideWith(() => readAhead),
        for (final id in [84, 85, 86]) ...[
          chapterProvider(chapterId: id).overrideWith((ref) => chapter(id)),
          chapterPagesProvider(chapterId: id).overrideWith((ref) async {
            if (id == 85) await nextPages.future;
            return Fragment$ChapterPagesDto(
              chapter: Fragment$ChapterPagesDto$chapter(id: id, pageCount: 3),
              pages: ['/one', '/two', '/three'],
            );
          }),
          offlineChapterPagesProvider(mangaId: 37, chapterId: id)
              .overrideWith((ref) async => files),
        ],
      ]);
      addTearDown(container.dispose);
      container.read(mangaBookRepositoryProvider);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<int>(
            valueListenable: selectedChapter,
            builder: (_, id, __) => ReaderScreen(mangaId: 37, chapterId: id),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final pending = container.read(readingProgressProvider)[37];
      expect(pending?.chapter.id, 84);
      expect(pending?.page, 0,
          reason: 'opening page zero is a reading event, including webtoon');
      expect(pending?.pending, isTrue);
      expect(books.writes, isEmpty,
          reason: 'only network writes are debounced');
      expect(readAhead.requests, contains((37, 84)));
      for (final id in [85, 86]) {
        selectedChapter.value = id;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(readAhead.requests, contains((37, id)),
            reason:
                'a reused reader must replenish without returning to summary');
        if (id == 85) {
          expect(nextPages.isCompleted, isFalse,
              reason: 'read-ahead must not wait for current-page requests');
          nextPages.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(container.read(readingProgressProvider)[37]?.chapter.id, id);
        expect(container.read(readingProgressProvider)[37]?.page, 0,
            reason:
                'the new chapter must not inherit the previous scroll controller');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await container.read(readingProgressProvider.notifier).flush();
      expect(books.writes, isNotEmpty);
      expect(books.writes.last.id, 86);
      expect(books.writes.last.patch.lastPageRead, 0);
      expect(container.read(readingProgressProvider)[37]?.pending, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
