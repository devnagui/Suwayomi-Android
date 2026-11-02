import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/updates/updates_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/update_status/update_status_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/widgets/stop_updates_button.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';

Map<String, dynamic> page(String type) => {
      '__typename': type,
      'nodes': [],
      'totalCount': 0,
      'pageInfo': {
        '__typename': 'PageInfo',
        'endCursor': null,
        'startCursor': null,
        'hasNextPage': false,
        'hasPreviousPage': false,
      },
    };

UpdateStatusDto status(bool running) => UpdateStatusDto.fromJson({
      '__typename': 'UpdateStatus',
      'isRunning': running,
      for (final name in [
        'completeJobs',
        'failedJobs',
        'pendingJobs',
        'runningJobs',
        'skippedJobs'
      ])
        name: {
          '__typename': 'UpdateStatusType',
          'mangas': page('MangaNodeList')
        },
      for (final name in ['skippedCategories', 'updatingCategories'])
        name: {
          '__typename': 'UpdateStatusCategoryType',
          'categories': page('CategoryNodeList'),
        },
    });

class FakeUpdatesRepository extends UpdatesRepository {
  FakeUpdatesRepository(GraphQLClient client) : super(client, client);
  int stops = 0;
  bool fail = false;
  int? stoppedManga;

  @override
  Future<void> stopUpdates({int? mangaId}) async {
    stops++;
    stoppedManga = mangaId;
    if (fail) throw StateError('Cancellation rejected');
  }
}

void main() {
  test(
      'repository scopes individual cancellations and preserves legacy global input',
      () async {
    final inputs = <Map<String, dynamic>>[];
    final client = GraphQLClient(
      link: Link.function((request, [forward]) {
        inputs
            .add(Map<String, dynamic>.from(request.variables['input'] as Map));
        return Stream.value(Response(response: const {}, data: {
          '__typename': 'Mutation',
          'updateStop': {'__typename': 'UpdateStopPayload'},
        }));
      }),
      cache: GraphQLCache(),
    );
    final repository = UpdatesRepository(client, client);
    await repository.stopUpdates(mangaId: 37);
    await repository.stopUpdates();
    expect(inputs.first, {
      'mangaIds': [37]
    });
    expect(inputs.last, isEmpty);
  });

  test('unsupported individual cancellation never retries a global stop',
      () async {
    var requests = 0;
    final client = GraphQLClient(
      link: Link.function((request, [forward]) {
        requests++;
        expect((request.variables['input'] as Map)['mangaIds'], [37]);
        return Stream.value(Response(
          response: const {},
          errors: [
            GraphQLError(
                message:
                    'Field mangaIds is not defined by type UpdateStopInput')
          ],
        ));
      }),
      cache: GraphQLCache(),
    );
    await expectLater(
        UpdatesRepository(client, client).stopUpdates(mangaId: 37),
        throwsException);
    expect(requests, 1);
  });

  late FakeUpdatesRepository repository;
  setUp(() {
    final client = GraphQLClient(
      link: Link.function((request, [forward]) => const Stream.empty()),
      cache: GraphQLCache(),
    );
    repository = FakeUpdatesRepository(client);
  });

  Widget app(bool running, {int? mangaId}) => ProviderScope(
        overrides: [
          updatesRepositoryProvider.overrideWithValue(repository),
          updatesSocketProvider
              .overrideWith((ref) => Stream.value(status(running))),
          updateSummaryProvider.overrideWith((ref) async => status(running)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              appBar: AppBar(actions: [StopUpdatesButton(mangaId: mangaId)])),
        ),
      );

  testWidgets('stop all requires confirmation and leaves library untouched',
      (tester) async {
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel all updates'));
    await tester.pumpAndSettle();
    expect(repository.stops, 0);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(repository.stops, 0);
    await tester.tap(find.byTooltip('Cancel all updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel all updates'));
    await tester.pumpAndSettle();
    expect(repository.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancellation failure is visible', (tester) async {
    repository.fail = true;
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel all updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel all updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cancellation rejected'), findsOneWidget);
  });

  testWidgets('idle updater cannot send a stop request', (tester) async {
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    expect(repository.stops, 0);
  });

  testWidgets('a manga cancel sends only that manga and never stop-all',
      (tester) async {
    await tester.pumpWidget(app(true, mangaId: 37));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel update'));
    await tester.pumpAndSettle();
    expect(repository.stops, 1);
    expect(repository.stoppedManga, 37);
    expect(find.byType(AlertDialog), findsNothing);
  });

  test('GraphQL stop failures propagate instead of reporting success',
      () async {
    final client = GraphQLClient(
      link: Link.function((request, [forward]) => Stream.value(Response(
            response: const {},
            errors: [GraphQLError(message: 'Forbidden')],
          ))),
      cache: GraphQLCache(),
    );
    await expectLater(
        UpdatesRepository(client, client).stopUpdates(), throwsException);
  });
}
