import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/widgets/chapter_actions/multi_chapters_actions_bottom_app_bar.dart';

ChapterDto chapter(int id, bool state) => ChapterDto(
      chapterNumber: id.toDouble(),
      fetchedAt: '1720000000',
      id: id,
      user: Fragment$ChapterDto$user(
        isBookmarked: state,
        isDownloaded: state,
        isRead: state,
        lastPageRead: 0,
        lastReadAt: '0',
      ),
      mangaId: 37,
      name: 'Chapter $id',
      pageCount: 10,
      sourceOrder: id,
      uploadDate: '1710000000',
      url: '/chapter/$id',
      meta: [],
    );

void main() {
  for (final size in [
    const Size(240, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(800, 1024),
  ]) {
    for (final bottomInset in [0.0, 24.0, 48.0]) {
      testWidgets('selection actions respect $bottomInset inset at $size',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = FakeViewPadding(
          bottom: bottomInset,
          left: size.width > size.height ? 24 : 0,
          right: size.width > size.height ? 24 : 0,
        );
        addTearDown(tester.view.reset);
        final selection = ValueNotifier({
          1: chapter(1, true),
          2: chapter(2, false),
        });
        addTearDown(selection.dispose);
        await tester.pumpWidget(ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: const SizedBox.expand(key: Key('available-body')),
              bottomNavigationBar: MultiChaptersActionsBottomAppBar(
                selectedChapters: selection,
                afterOptionSelected: () async {},
                onChaptersUpdated: (_) async {},
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final icons = find.byType(IconButton);
        expect(icons, findsNWidgets(6));
        for (final element in icons.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.bottom, lessThanOrEqualTo(size.height - bottomInset));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
        }
        final bar =
            tester.getRect(find.byType(MultiChaptersActionsBottomAppBar));
        final body = tester.getRect(find.byKey(const Key('available-body')));
        expect(body.bottom, lessThanOrEqualTo(bar.top));
        final surface = tester.widget<Material>(find
            .descendant(
              of: find.byType(MultiChaptersActionsBottomAppBar),
              matching: find.byType(Material),
            )
            .first);
        expect(surface.color?.a, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
