import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tachidesk_sorayomi/src/constants/navigation_bar_data.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/activity/activity_screen.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/routes/router_config.dart';
import 'package:tachidesk_sorayomi/src/widgets/shell/big_screen_navigation_bar.dart';
import 'package:tachidesk_sorayomi/src/widgets/shell/small_screen_navigation_bar.dart';

StatefulShellRoute activityRoute() {
  final quickSearch = $appRoutes.first as ShellRoute;
  final navigation = quickSearch.routes.first as StatefulShellRoute;
  return navigation.branches[1].routes.single as StatefulShellRoute;
}

GoRouter testRouter(String location) {
  final activity = activityRoute();
  return GoRouter(
    initialLocation: location,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: const ActivityShellRoute().builder,
        branches: [
          for (final branch in activity.branches)
            StatefulShellBranch(
              routes: [
                for (final route in branch.routes.cast<GoRoute>())
                  GoRoute(
                    path: route.path,
                    builder: (_, __) => _Section(name: route.path),
                  ),
              ],
            ),
        ],
      ),
      GoRoute(
        path: Routes.activity,
        redirect: const ActivityRoute().redirect,
      ),
    ],
  );
}

Widget app(GoRouter router, {Locale locale = const Locale('en')}) =>
    MaterialApp.router(
      routerConfig: router,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

void main() {
  test('Activity owns both unchanged legacy routes in one top-level branch',
      () {
    final quickSearch = $appRoutes.first as ShellRoute;
    final navigation = quickSearch.routes.first as StatefulShellRoute;
    expect(navigation.branches, hasLength(5));
    expect(activityRoute().branches, hasLength(2));
    expect((activityRoute().branches[0].routes.single as GoRoute).path,
        const UpdatesRoute().location);
    expect((activityRoute().branches[1].routes.single as GoRoute).path,
        const DownloadsRoute().location);
    expect(NavigationBarData.phoneNavList, hasLength(4));
    expect(NavigationBarData.tabletNavList, hasLength(5));
    for (final isTablet in [false, true]) {
      final indices = isTablet
          ? NavigationBarData.tabletBranchIndices
          : NavigationBarData.phoneBranchIndices;
      for (var destination = 0; destination < indices.length; destination++) {
        final branch = NavigationBarData.branchIndexForDestination(
          destination,
          isTablet: isTablet,
        );
        expect(branch, indices[destination]);
        expect(
          NavigationBarData.destinationIndexForBranch(
            branch,
            isTablet: isTablet,
          ),
          destination,
        );
      }
    }
    expect(
      NavigationBarData.destinationIndexForBranch(2, isTablet: false),
      3,
    );
  });

  for (final entry in {
    '/activity': 0,
    '/updates': 0,
    '/downloads': 1,
  }.entries) {
    testWidgets('${entry.key} opens the correct Activity section',
        (tester) async {
      final router = testRouter(entry.key);
      addTearDown(router.dispose);
      await tester.pumpWidget(app(router));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
        entry.value,
      );
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(
        router.routeInformationProvider.value.uri.path,
        entry.value == 0 ? '/updates' : '/downloads',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('section switching retains scroll, selection and direct links',
      (tester) async {
    final router = testRouter('/updates');
    addTearDown(router.dispose);
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select'));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final updatesState = tester.state<_SectionState>(find.byType(_Section));
    final offset = updatesState.scrollController.offset;
    expect(offset, greaterThan(0));
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/downloads');
    await tester.tap(find.byTooltip('Select'));
    router.go('/updates');
    await tester.pumpAndSettle();
    expect(
        tester.state<_SectionState>(find.byType(_Section)), same(updatesState));
    expect(updatesState.scrollController.offset, offset);
    expect(find.text('Selected 1'), findsOneWidget);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [
    const Locale('en'),
    const Locale('pt'),
    const Locale('pt', 'BR'),
    const Locale('pt', 'PT'),
    const Locale('fr'),
  ]) {
    testWidgets('Activity label is localized with fallback for $locale',
        (tester) async {
      final router = testRouter('/updates');
      addTearDown(router.dispose);
      await tester.pumpWidget(app(router, locale: locale));
      await tester.pumpAndSettle();
      expect(find.text(locale.languageCode == 'pt' ? 'Atividade' : 'Activity'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(800, 1024),
    const Size(1200, 900),
  ]) {
    testWidgets('unified navigation respects safe areas at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        top: 24,
        bottom: 48,
        left: 24,
        right: 24,
      );
      addTearDown(tester.view.reset);
      final tablet = size.width >= 600;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: tablet
              ? Row(children: [
                  BigScreenNavigationBar(
                    selectedIndex: 1,
                    onDestinationSelected: (_) {},
                  ),
                  const Expanded(child: SizedBox()),
                ])
              : const SizedBox(),
          bottomNavigationBar: tablet
              ? null
              : SmallScreenNavigationBar(
                  selectedIndex: 1,
                  onDestinationSelected: (_) {},
                ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Downloads'), findsNothing);
      expect(find.text('Updates'), findsNothing);
      final label = tester.getRect(find.text('Activity'));
      expect(label.left, greaterThanOrEqualTo(24));
      expect(label.right, lessThanOrEqualTo(size.width - 24));
      expect(label.top, greaterThanOrEqualTo(24));
      expect(label.bottom, lessThanOrEqualTo(size.height - 48));
      expect(tester.takeException(), isNull);
    });
  }
}

class _Section extends StatefulWidget {
  const _Section({required this.name});

  final String name;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  final scrollController = ScrollController();
  var selected = 0;

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(AppLocalizations.of(context)!.activity),
          bottom: const ActivityTabs(),
          actions: [
            IconButton(
              tooltip: 'Select',
              onPressed: () => setState(() => selected++),
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: Column(
          children: [
            Text('Selected $selected'),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemExtent: 80,
                itemCount: 100,
                itemBuilder: (_, index) =>
                    ListTile(title: Text('${widget.name} $index')),
              ),
            ),
          ],
        ),
      );
}
