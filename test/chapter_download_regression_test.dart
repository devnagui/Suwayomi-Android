import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/downloads/downloads_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/data/manga_book/manga_book_repository.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter_batch/chapter_batch_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads/downloads_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/downloads_queue/downloads_queue_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/downloads/controller/downloads_controller.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/presentation/manga_details/controller/manga_details_controller.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/widgets/chapter_actions/multi_chapters_actions_bottom_app_bar.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/extensions/custom_extensions.dart';

GraphQLClient errorClient() => GraphQLClient(
      link: Link.function((request, [forward]) async* {
        yield Response(
          response: const {},
          errors: [GraphQLError(message: 'Mutation rejected')],
        );
      }),
      cache: GraphQLCache(),
    );

ChapterDto chapter(int id, {bool isRead = false}) => ChapterDto(
      chapterNumber: id.toDouble(),
      fetchedAt: '1720000000',
      id: id,
      user: Fragment$ChapterDto$user(
        isBookmarked: false,
        isDownloaded: false,
        isRead: isRead,
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

class MangaRepositoryStub extends MangaBookRepository {
  MangaRepositoryStub(
    super.client,
    super.ref,
    this.chapters, {
    this.modify,
  });

  final List<ChapterDto> chapters;
  final Future<List<ChapterDto>?> Function(ChapterBatch batch)? modify;
  int chapterListRequests = 0;

  @override
  Future<List<ChapterDto>?> getChapterList(int mangaId) async {
    chapterListRequests++;
    return chapters;
  }

  @override
  Future<List<ChapterDto>?> modifyBulkChapters(ChapterBatch batch) =>
      modify?.call(batch) ?? super.modifyBulkChapters(batch);
}

void main() {
  test('chapter mutations throw GraphQL errors through getData', () async {
    final client = errorClient();
    final container = ProviderContainer(
      overrides: [graphQlClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    final repository = container.read(mangaBookRepositoryProvider);

    await expectLater(
      repository.putChapter(
        chapterId: 1,
        patch: ChapterChange(isRead: true),
      ),
      throwsA(isA<OperationMessageException>()),
    );
    await expectLater(
      repository.modifyBulkChapters(
        ChapterBatch(
          ids: [1, 2],
          patch: ChapterChange(isRead: true),
        ),
      ),
      throwsA(isA<OperationMessageException>()),
    );
  });

  test('download control mutations throw GraphQL errors through getData',
      () async {
    final client = errorClient();
    final repository = DownloadsRepository(client, client);

    for (final mutation in <Future<void> Function()>[
      repository.startDownloads,
      repository.stopDownloads,
      repository.clearDownloads,
      () => repository.addChaptersBatchToDownloadQueue([1]),
      () => repository.removeChapterFromDownloadQueue(1),
    ]) {
      await expectLater(
        mutation(),
        throwsA(isA<OperationMessageException>()),
      );
    }
  });

  test('local chapter merge does not refetch the full chapter list', () async {
    late MangaRepositoryStub repository;
    final client = errorClient();
    final container = ProviderContainer(
      overrides: [
        mangaBookRepositoryProvider.overrideWith((ref) {
          repository = MangaRepositoryStub(client, ref, [chapter(1)]);
          return repository;
        }),
      ],
    );
    addTearDown(container.dispose);
    final provider = mangaChapterListProvider(mangaId: 37);
    final subscription = container.listen(provider, (_, __) {});
    addTearDown(subscription.close);

    await container.read(provider.future);
    container
        .read(provider.notifier)
        .updateChapters([chapter(1, isRead: true)]);

    expect(container.read(provider).valueOrNull?.single.isRead, isTrue);
    expect(repository.chapterListRequests, 1);
  });

  testWidgets('batch action preserves selection on mutation failure',
      (tester) async {
    final selected = ValueNotifier({1: chapter(1)});
    addTearDown(selected.dispose);
    final client = errorClient();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaBookRepositoryProvider.overrideWith(
            (ref) => MangaRepositoryStub(
              client,
              ref,
              const [],
              modify: (_) => Future.error(StateError('rejected')),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            bottomNavigationBar: MultiChaptersActionsBottomAppBar(
              selectedChapters: selected,
              afterOptionSelected: () async {},
              onChaptersUpdated: (_) async {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.done_all_rounded));
    await tester.pumpAndSettle();
    expect(selected.value, contains(1));
  });

  testWidgets('batch action clears selection after successful local merge',
      (tester) async {
    final selected = ValueNotifier({1: chapter(1)});
    addTearDown(selected.dispose);
    final updated = chapter(1, isRead: true);
    final client = errorClient();
    var merged = <ChapterDto>[];
    var fullRefreshes = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaBookRepositoryProvider.overrideWith(
            (ref) => MangaRepositoryStub(
              client,
              ref,
              const [],
              modify: (_) async => [updated],
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            bottomNavigationBar: MultiChaptersActionsBottomAppBar(
              selectedChapters: selected,
              afterOptionSelected: () async => fullRefreshes++,
              onChaptersUpdated: (chapters) async => merged = chapters,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.done_all_rounded));
    await tester.pumpAndSettle();
    expect(merged.single.isRead, isTrue);
    expect(selected.value, isEmpty);
    expect(fullRefreshes, 0);
  });

  test('HTTP status survives subscription errors and can be refreshed',
      () async {
    var statusRequests = 0;
    final status = DownloadStatusDto(
      state: DownloaderState.STARTED,
      queue: const [],
    );
    final container = ProviderContainer(
      overrides: [
        downloadUpdatesProvider.overrideWith(
          (ref) => Stream<DownloadUpdatesDto?>.error(
            StateError('subscription unavailable'),
          ),
        ),
        downloadStatusProvider.overrideWith((ref) async {
          statusRequests++;
          return status;
        }),
      ],
    );
    addTearDown(container.dispose);
    final stateSubscription =
        container.listen(downloaderStateProvider, (_, __) {});
    final mapSubscription = container.listen(downloadsMapProvider, (_, __) {});
    addTearDown(stateSubscription.close);
    addTearDown(mapSubscription.close);

    await container.read(downloadStatusProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(downloaderStateProvider).valueOrNull,
      DownloaderState.STARTED,
    );

    await container.read(downloadsMapProvider.notifier).refresh();
    expect(statusRequests, 2);
    expect(container.read(downloadsMapProvider), isEmpty);
  });
}
