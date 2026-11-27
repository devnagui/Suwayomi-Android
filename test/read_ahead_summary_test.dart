import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/widgets/read_ahead_summary.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_smart_download_tile/reader_smart_download_tile.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/utils/network/reader_read_ahead.dart';

ChapterDto chapter(int id, {int mangaId = 37}) => ChapterDto(
      chapterNumber: id.toDouble(),
      fetchedAt: '1720000000',
      id: id,
      user: Fragment$ChapterDto$user(
        isBookmarked: false,
        isDownloaded: false,
        isRead: false,
        lastPageRead: 0,
        lastReadAt: '0',
      ),
      mangaId: mangaId,
      name: 'Chapter $id with a long title that must fit on a narrow phone',
      pageCount: 10,
      sourceOrder: id,
      uploadDate: '1710000000',
      url: '/chapter/$id',
      meta: [],
    );

class FakeReadAhead extends ReaderReadAhead {
  FakeReadAhead(this.statuses);

  final Map<int, ReadAheadStatus> statuses;
  int? retried;

  @override
  Map<int, ReadAheadStatus> build() => statuses;

  @override
  void retry(int chapterId) {
    retried = chapterId;
    state = {
      ...state,
      chapterId: ReadAheadStatus(
        chapter: state[chapterId]!.chapter,
        phase: ReadAheadPhase.waiting,
      ),
    };
  }
}

class FailingSetting extends SmartDownloadNextChapter {
  @override
  bool build() => false;

  @override
  Future<void> update(bool value) async =>
      throw StateError('private persistence error must not be displayed');
}

Widget app(FakeReadAhead service,
        {Locale locale = const Locale('en'), bool tablet = false}) =>
    ProviderScope(
      overrides: [readerReadAheadProvider.overrideWith(() => service)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: tablet
              ? const Row(children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: ReadAheadSummary(mangaId: 37),
                    ),
                  ),
                  Expanded(child: SizedBox()),
                ])
              : const SingleChildScrollView(
                  child: ReadAheadSummary(mangaId: 37),
                ),
        ),
      ),
    );

void main() {
  testWidgets('active download stays visible when the window advances',
      (tester) async {
    await tester.pumpWidget(app(FakeReadAhead({
      1: ReadAheadStatus(
          chapter: chapter(1), phase: ReadAheadPhase.downloading, progress: .5),
      for (var id = 2; id <= 4; id++)
        id: ReadAheadStatus(
            chapter: chapter(id), phase: ReadAheadPhase.waiting),
    })));
    await tester.pump();
    expect(find.text('Downloading on server · 50%'), findsOneWidget);
    expect(find.text(chapter(1).name), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  for (final size in [const Size(240, 640), const Size(800, 1024)]) {
    for (final phase in ReadAheadPhase.values) {
      testWidgets('$phase fits summary at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final progress = switch (phase) {
          ReadAheadPhase.downloading => 0.5,
          ReadAheadPhase.copying => 0.75,
          _ => null,
        };
        await tester.pumpWidget(app(
          FakeReadAhead({
            1: ReadAheadStatus(
              chapter: chapter(1),
              phase: phase,
              progress: progress,
              attempt: phase == ReadAheadPhase.retrying ? 2 : 1,
              reasonCode: 'private diagnostic must not be displayed',
            ),
            2: ReadAheadStatus(
                chapter: chapter(2), phase: ReadAheadPhase.waiting),
            3: ReadAheadStatus(
                chapter: chapter(3), phase: ReadAheadPhase.ready),
          }),
          tablet: size.width >= 800,
        ));
        await tester.pump();
        final expected = switch (phase) {
          ReadAheadPhase.waiting => 'Waiting for its turn',
          ReadAheadPhase.requesting => 'Requesting from server',
          ReadAheadPhase.downloading => 'Downloading on server · 50%',
          ReadAheadPhase.copying => 'Saving to device · 75%',
          ReadAheadPhase.retrying => 'Waiting to retry · Attempt 2',
          ReadAheadPhase.paused => 'Paused — waiting for downloads to resume',
          ReadAheadPhase.ready => 'Ready on device',
          ReadAheadPhase.failed => 'Could not prepare chapter',
          ReadAheadPhase.cancelled => 'Preparation cancelled',
        };
        expect(find.text(expected), findsWidgets);
        expect(find.textContaining('private'), findsNothing);
        final hasProgress = phase == ReadAheadPhase.requesting ||
            phase == ReadAheadPhase.downloading ||
            phase == ReadAheadPhase.copying ||
            phase == ReadAheadPhase.retrying;
        expect(find.byType(LinearProgressIndicator),
            hasProgress ? findsOneWidget : findsNothing);
        if (hasProgress) {
          expect(
              tester
                  .widget<LinearProgressIndicator>(
                      find.byType(LinearProgressIndicator))
                  .value,
              progress);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('only latest three statuses of this manga appear',
      (tester) async {
    await tester.pumpWidget(app(FakeReadAhead({
      for (final id in [1, 2, 3, 4])
        id: ReadAheadStatus(chapter: chapter(id), phase: ReadAheadPhase.ready),
      5: ReadAheadStatus(
          chapter: chapter(5, mangaId: 99), phase: ReadAheadPhase.failed),
    })));
    expect(find.text(chapter(1).name), findsNothing);
    for (final id in [2, 3, 4]) {
      expect(find.text(chapter(id).name), findsOneWidget);
    }
    expect(find.text(chapter(5).name), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('summary is absent for empty state or another manga',
      (tester) async {
    await tester.pumpWidget(app(FakeReadAhead({})));
    expect(find.byType(Card), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(FakeReadAhead({
      1: ReadAheadStatus(
          chapter: chapter(1, mangaId: 99), phase: ReadAheadPhase.downloading),
    })));
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('explicit Retry targets the failed chapter', (tester) async {
    final service = FakeReadAhead({
      7: ReadAheadStatus(
          chapter: chapter(7), phase: ReadAheadPhase.failed, attempt: 3),
    });
    await tester.pumpWidget(app(service));
    expect(find.text('Could not prepare chapter · Attempt 3'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(service.retried, 7);
    expect(find.text('Waiting for its turn'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Ready on device'), findsNothing);
  });

  for (final locale in [
    const Locale('pt'),
    const Locale('pt', 'BR'),
    const Locale('pt', 'PT'),
  ]) {
    testWidgets('Portuguese summary labels for $locale', (tester) async {
      await tester.pumpWidget(app(
        FakeReadAhead({
          1: ReadAheadStatus(chapter: chapter(1), phase: ReadAheadPhase.ready),
        }),
        locale: locale,
      ));
      await tester.pump();
      expect(find.text('Preparar próximos capítulos'), findsOneWidget);
      expect(find.text('Pronto no dispositivo'), findsOneWidget);
    });
  }

  testWidgets('setting persistence failure is safe and keeps saved value',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        smartDownloadNextChapterProvider.overrideWith(FailingSetting.new),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ReaderSmartDownloadTile()),
      ),
    ));
    expect(
      find.text('Automatically prepare the next 3 chapters on this device '
          'while reading, one at a time, with retries.'),
      findsOneWidget,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
    expect(find.text('Could not save this setting. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
