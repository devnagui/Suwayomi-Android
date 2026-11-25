import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter_page/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/utils/reader_scroll_physics.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/reader/widgets/directional_swipe_gesture_handler.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/reader/widgets/reader_swipe_toggle_tile/reader_swipe_chapter_toggle_tile.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';

void main() {
  Future<ProviderContainer> preferences(bool? enabled) async {
    SharedPreferences.setMockInitialValues({
      if (enabled != null) DBKeys.swipeToggle.name: enabled,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  for (final axis in Axis.values) {
    for (final reverse in [false, true]) {
      testWidgets('paged $axis reverse=$reverse obeys live swipe setting',
          (tester) async {
        final container = await preferences(false);
        final controller = PageController(initialPage: 1);
        addTearDown(controller.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(builder: (context, ref, _) {
                return PageView(
                  controller: controller,
                  scrollDirection: axis,
                  reverse: reverse,
                  physics: ref.watch(readerScrollPhysicsProvider(axis)) ??
                      const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics()),
                  children: List.generate(
                    4,
                    (_) => GestureDetector(
                      onTap: () => controller.jumpToPage(2),
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                );
              }),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final delta = axis == Axis.horizontal
            ? const Offset(-600, 0)
            : const Offset(0, -450);
        final forward = reverse ? -delta : delta;
        await tester.drag(find.byType(PageView), forward);
        await tester.pumpAndSettle();
        expect(controller.page, axis == Axis.horizontal ? 1 : 2);
        controller.jumpToPage(1);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(PageView), -forward);
        await tester.pumpAndSettle();
        expect(controller.page, axis == Axis.horizontal ? 1 : 0);

        controller.jumpToPage(1);
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getCenter(find.byType(PageView)));
        await tester.pumpAndSettle();
        expect(controller.page, 2, reason: 'tap navigation remains available');

        controller.jumpToPage(1);
        container.read(swipeChapterToggleProvider.notifier).update(true);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(PageView), forward);
        await tester.pumpAndSettle();
        expect(controller.page, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('continuous $axis reverse=$reverse obeys swipe setting',
          (tester) async {
        final container = await preferences(false);
        final controller = ItemScrollController();
        final positions = ItemPositionsListener.create();
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(builder: (context, ref, _) {
                return ScrollablePositionedList.builder(
                  itemScrollController: controller,
                  itemPositionsListener: positions,
                  initialScrollIndex: 1,
                  itemCount: 5,
                  scrollDirection: axis,
                  reverse: reverse,
                  physics: ref.watch(readerScrollPhysicsProvider(axis)),
                  itemBuilder: (_, index) => SizedBox(
                    width: 800,
                    height: 600,
                    child: ColoredBox(
                      color: Colors.blue,
                      child: Center(child: Text('Page $index')),
                    ),
                  ),
                );
              }),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        double leadingEdge() => positions.itemPositions.value
            .firstWhere((p) => p.index == 1)
            .itemLeadingEdge;
        final initial = leadingEdge();
        final delta = axis == Axis.horizontal
            ? const Offset(-300, 0)
            : const Offset(0, -300);
        final forward = reverse ? -delta : delta;
        await tester.drag(find.byType(ScrollablePositionedList), forward);
        await tester.pumpAndSettle();
        expect(leadingEdge(),
            axis == Axis.horizontal ? initial : lessThan(initial));
        controller.jumpTo(index: 1);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ScrollablePositionedList), -forward);
        await tester.pumpAndSettle();
        expect(leadingEdge(),
            axis == Axis.horizontal ? initial : greaterThan(initial));
        controller.jumpTo(index: 2);
        await tester.pumpAndSettle();
        expect(find.text('Page 2').hitTestable(), findsOneWidget,
            reason: 'slider/programmatic navigation remains available');

        controller.jumpTo(index: 1);
        container.read(swipeChapterToggleProvider.notifier).update(true);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ScrollablePositionedList), forward);
        await tester.pumpAndSettle();
        expect(leadingEdge(), lessThan(initial));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  test('unset preference preserves enabled horizontal swiping', () async {
    final container = await preferences(null);
    expect(
        container.read(readerScrollPhysicsProvider(Axis.horizontal)), isNull);
    container.read(swipeChapterToggleProvider.notifier).update(false);
    expect(container.read(readerScrollPhysicsProvider(Axis.horizontal)),
        isA<NeverScrollableScrollPhysics>());
    expect(container.read(readerScrollPhysicsProvider(Axis.vertical)), isNull);
  });

  for (final lastPageSwipeEnabled in [false, true]) {
    testWidgets(
        'disabled swipes preserve taps/zoom with last-page swipe=$lastPageSwipeEnabled',
        (tester) async {
      final transform = TransformationController();
      addTearDown(transform.dispose);
      var taps = 0;
      var longPresses = 0;
      await tester.pumpWidget(MaterialApp(
        home: DirectionalSwipeGestureHandler(
          onTap: () => taps++,
          onLongPressStart: (_) => longPresses++,
          onLongPressEnd: (_) {},
          onLongPressMoveUpdate: (_) {},
          scrollDirection: Axis.horizontal,
          readerSwipeChapterToggle: false,
          lastPageSwipeEnabled: lastPageSwipeEnabled,
          resolvedReaderMode: ReaderMode.singleHorizontalLTR,
          currentIndex: 0,
          chapterPages: Fragment$ChapterPagesDto(
            chapter: Fragment$ChapterPagesDto$chapter(id: 1, pageCount: 1),
            pages: ['page'],
          ),
          mangaId: 1,
          prevNextChapterPair: null,
          onNextPage: () => fail('Disabled swipe must not navigate'),
          onPreviousPage: () => fail('Disabled swipe must not navigate'),
          pageController: null,
          child: InteractiveViewer(
            transformationController: transform,
            maxScale: 5,
            child: const SizedBox.expand(
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ));
      await tester.tapAt(const Offset(400, 300));
      expect(taps, 1);
      await tester.drag(find.byType(InteractiveViewer), const Offset(-250, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(InteractiveViewer), const Offset(250, 0));
      await tester.pumpAndSettle();
      await tester.longPressAt(const Offset(400, 300));
      expect(longPresses, 1);
      final left =
          await tester.startGesture(const Offset(300, 300), pointer: 1);
      final right =
          await tester.startGesture(const Offset(500, 300), pointer: 2);
      await tester.pump();
      await left.moveTo(const Offset(200, 300));
      await right.moveTo(const Offset(600, 300));
      await tester.pump();
      await left.moveTo(const Offset(150, 300));
      await right.moveTo(const Offset(650, 300));
      await tester.pump();
      expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      final before = transform.value.clone();
      await tester.drag(find.byType(InteractiveViewer), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(transform.value, isNot(before));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
