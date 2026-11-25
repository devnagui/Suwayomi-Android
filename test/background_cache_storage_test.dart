import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_http_client.dart';
import 'package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart';

Stream<List<int>> interruptedBody() async* {
  yield [1, 2];
  throw const HttpException('private URL must not appear in progress');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('background-cache-');
    SharedPreferences.setMockInitialValues({
      DBKeys.serverUrl.name: 'http://server.test',
      DBKeys.serverPortToggle.name: false,
    });
    preferences = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  OfflineChapterManager manager({http.Client? client}) {
    final media = client ??
        MockClient((_) async => http.Response.bytes([1, 2, 3], 200));
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      serverMediaHttpClientProvider.overrideWithValue(media),
    ]);
    addTearDown(container.dispose);
    addTearDown(media.close);
    final provider = Provider((ref) => OfflineChapterManager(
          ref,
          documentsDirectory: () async => directory,
        ));
    return container.read(provider);
  }

  Future<List<LocalDownloadProgress>> save(
          OfflineChapterManager cache, int chapterId,
          {List<String> pages = const ['/api/v1/page/0']}) =>
      cache
          .downloadChapter(mangaId: 7, chapterId: chapterId, pageUrls: pages)
          .toList();

  Future<void> seedLegacy(int chapterId, {int count = 1}) async {
    final raw = preferences.getString('offline_chapters_metadata');
    final metadata =
        raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    metadata['7_$chapterId'] = {
      'mangaId': 7,
      'chapterId': chapterId,
      'pageCount': count,
    };
    await preferences.setString(
        'offline_chapters_metadata', jsonEncode(metadata));
    final chapter =
        Directory(p.join(directory.path, 'offline_manga', '7', '$chapterId'));
    await chapter.create(recursive: true);
    for (var i = 0; i < count; i++) {
      await File(p.join(chapter.path, '$i.jpg')).writeAsBytes([9]);
    }
  }

  test('failed streamed body never publishes pages or completion', () async {
    final cache = manager(
        client: MockClient.streaming((request, body) async =>
            http.StreamedResponse(interruptedBody(), 200)));
    final progress = await save(cache, 10);
    expect(progress.any((event) => event.isComplete), isFalse);
    expect(progress.last.error, isNotNull);
    expect(progress.last.error, isNot(contains('private URL')));
    expect(await cache.isChapterAvailableOffline(7, 10), isFalse);
    expect(await cache.getOfflinePages(7, 10), isNull);
    expect(
        await Directory(p.join(directory.path, 'offline_manga'))
            .list(recursive: true)
            .where((entity) => entity is File)
            .toList(),
        isEmpty);
  });

  for (final body in [<int>[], [1, 2]]) {
    test('empty or truncated successful HTTP body cannot complete: $body',
        () async {
      final cache = manager(
          client: MockClient((_) async => http.Response.bytes(body, 200,
              headers: {'content-length': '20'})));
      final progress = await save(cache, 10);
      expect(progress.last.isComplete, isFalse);
      expect(progress.last.error, isNotNull);
      expect(await cache.isChapterAvailableOffline(7, 10), isFalse);
    });
  }

  test('unpublished interrupted page files are not legacy cache hits', () async {
    final chapter =
        Directory(p.join(directory.path, 'offline_manga', '7', '10'));
    await chapter.create(recursive: true);
    await File(p.join(chapter.path, '0.jpg')).writeAsBytes([1, 2]);
    final temporary = await chapter.createTemp('.pending-');
    await File(p.join(temporary.path, 'body')).writeAsBytes([1]);
    final cache = manager();
    expect(await cache.isChapterAvailableOffline(7, 10), isFalse);
    expect(await cache.getOfflineChapterIds(7), isEmpty);
  });

  test('two independent managers publish chapters without whole-map lost writes',
      () async {
    await seedLegacy(9);
    final legacy = preferences.getString('offline_chapters_metadata');
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = manager(client: MockClient((_) async {
      entered.complete();
      await release.future;
      return http.Response.bytes([1, 2, 3], 200);
    }));
    final firstSave = save(first, 10);
    await entered.future;
    final second = manager();
    expect((await save(second, 11)).last.isComplete, isTrue);
    release.complete();
    expect((await firstSave).last.isComplete, isTrue);

    final restarted = manager();
    expect(await restarted.getOfflineChapterIds(7), unorderedEquals([9, 10, 11]));
    for (final id in [9, 10, 11]) {
      expect(await restarted.isChapterAvailableOffline(7, id), isTrue);
      expect(await restarted.getOfflinePages(7, id), hasLength(1));
    }
    expect(preferences.getString('offline_chapters_metadata'), legacy);
  });

  test('manual exclusion persists, and explicit allowance permits a fresh save',
      () async {
    final cache = manager();
    expect((await save(cache, 10)).last.isComplete, isTrue);
    await cache.deleteOfflineChapter(7, 10);
    final restarted = manager();
    expect(await restarted.isAutomaticallyExcluded(7, 10), isTrue);
    expect(await restarted.getOfflineChapterIds(7), isEmpty);
    expect((await save(restarted, 10)).last.error, isNotNull);
    expect(await restarted.isChapterAvailableOffline(7, 10), isFalse);

    await restarted.allowAutomaticCache(7, 10);
    final allowed = manager();
    expect(await allowed.isAutomaticallyExcluded(7, 10), isFalse);
    expect((await save(allowed, 10)).last.isComplete, isTrue);
    expect(await allowed.isChapterAvailableOffline(7, 10), isTrue);
  });

  test('removal while page is in flight cannot resurrect after explicit allow',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final cache = manager(client: MockClient((_) async {
      entered.complete();
      await release.future;
      return http.Response.bytes([1, 2, 3], 200);
    }));
    final work = save(cache, 10);
    await entered.future;
    final foreground = manager();
    await foreground.deleteOfflineChapter(7, 10);
    await foreground.allowAutomaticCache(7, 10);
    release.complete();
    final progress = await work;
    expect(progress.any((event) => event.isComplete), isFalse);
    expect(progress.last.error, isNotNull);
    expect(await foreground.isChapterAvailableOffline(7, 10), isFalse);
    expect((await save(foreground, 10)).last.isComplete, isTrue);
  });

  test('legacy availability requires a nonzero, nonempty complete file set',
      () async {
    await seedLegacy(9);
    await seedLegacy(10, count: 0);
    await seedLegacy(11, count: 2);
    await File(p.join(directory.path, 'offline_manga', '7', '11', '1.jpg'))
        .writeAsBytes([]);
    final cache = manager();
    expect(await cache.isChapterAvailableOffline(7, 9), isTrue);
    expect(await cache.isChapterAvailableOffline(7, 10), isFalse);
    expect(await cache.isChapterAvailableOffline(7, 11), isFalse);
    expect(await cache.getOfflineChapterIds(7), [9]);
    await cache.deleteOfflineChapter(7, 9);
    await cache.allowAutomaticCache(7, 9);
    // Read-only legacy metadata must not restore a manually removed cache.
    expect(await cache.isChapterAvailableOffline(7, 9), isFalse);
  });

  test('clear persists exclusions for legacy, manifest and in-flight chapters',
      () async {
    await seedLegacy(9);
    final foreground = manager();
    await save(foreground, 10);
    final entered = Completer<void>();
    final release = Completer<void>();
    final worker = manager(client: MockClient((_) async {
      entered.complete();
      await release.future;
      return http.Response.bytes([1, 2, 3], 200);
    }));
    final work = save(worker, 11);
    await entered.future;
    final legacy = preferences.getString('offline_chapters_metadata');
    await foreground.clearAllOfflineData();
    release.complete();
    expect((await work).last.error, isNotNull);
    final restarted = manager();
    for (final id in [9, 10, 11]) {
      expect(await restarted.isAutomaticallyExcluded(7, id), isTrue);
      expect(await restarted.isChapterAvailableOffline(7, id), isFalse);
      expect((await save(restarted, id)).last.error, isNotNull);
    }
    expect(await restarted.getOfflineChapterIds(7), isEmpty);
    expect(preferences.getString('offline_chapters_metadata'), legacy);
    await restarted.allowAutomaticCache(7, 10);
    expect((await save(restarted, 10)).last.isComplete, isTrue);
  });

  test('completion is emitted only after its manifest is readable', () async {
    final cache = manager();
    await for (final progress in cache.downloadChapter(
      mangaId: 7,
      chapterId: 10,
      pageUrls: ['/api/v1/page/0', '/api/v1/page/1'],
    )) {
      expect(await cache.isChapterAvailableOffline(7, 10), progress.isComplete);
    }
    final pages = (await cache.getOfflinePages(7, 10))!;
    await pages.last.delete();
    expect(await cache.isChapterAvailableOffline(7, 10), isFalse);
  });
}
