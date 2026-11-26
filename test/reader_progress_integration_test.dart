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
import 'package:tachidesk_sorayomi/src/utils/network/reading_progress.dart';

import 'chapter_download_regression_test.dart' show chapter;
import 'reading_progress_test.dart' show Books;

void main() {
  for (final mode in [ReaderMode.singleHorizontalLTR, ReaderMode.webtoon]) {
    testWidgets('$mode records its first page and flushes on reader exit',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        DBKeys.readerMode.name: mode.index,
        DBKeys.smartDownloadNextChapter.name: false,
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
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        readingProgressScopeProvider.overrideWithValue('reader_test'),
        mangaBookRepositoryProvider.overrideWith((ref) => books = Books(ref)),
        chapterProvider(chapterId: 84).overrideWith((ref) => chapter(84)),
        chapterPagesProvider(chapterId: 84)
            .overrideWith((ref) async => Fragment$ChapterPagesDto(
                  chapter:
                      Fragment$ChapterPagesDto$chapter(id: 84, pageCount: 3),
                  pages: ['/one', '/two', '/three'],
                )),
        offlineChapterPagesProvider(mangaId: 37, chapterId: 84)
            .overrideWith((ref) async => files),
      ]);
      addTearDown(container.dispose);
      container.read(mangaBookRepositoryProvider);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ReaderScreen(mangaId: 37, chapterId: 84),
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
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await container.read(readingProgressProvider.notifier).flush();
      expect(books.writes, isNotEmpty);
      expect(books.writes.last.id, 84);
      expect(books.writes.last.patch.lastPageRead, 0);
      expect(container.read(readingProgressProvider)[37]?.pending, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
