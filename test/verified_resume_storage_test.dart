import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
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

late List<int> png;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('verified-resume-');
    SharedPreferences.setMockInitialValues({
      DBKeys.serverUrl.name: 'http://server.test',
      DBKeys.serverPortToggle.name: false,
    });
    preferences = await SharedPreferences.getInstance();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });
  tearDown(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 32 || attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  OfflineChapterManager manager(http.Client client,
      {Future<int> Function(String)? availableBytes,
      Future<void> Function(File)? imageValidator}) {
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      serverMediaHttpClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);
    return container.read(Provider((ref) => OfflineChapterManager(ref,
        documentsDirectory: () async => directory,
        availableBytes: availableBytes ?? (_) async => 1 << 40,
        imageValidator: imageValidator)));
  }

  Future<List<LocalDownloadProgress>> save(OfflineChapterManager cache,
          {List<String> urls = const ['/page/0', '/page/1']}) =>
      cache.downloadChapter(mangaId: 7, chapterId: 10, pageUrls: urls).toList();

  Future<void> interrupted() async {
    final cache = manager(MockClient((request) async {
      if (request.url.path.endsWith('/1')) {
        throw const SocketException('interrupted');
      }
      return http.Response.bytes(png, 200);
    }));
    final events = await save(cache);
    expect(events.last.isComplete, isFalse);
    expect(events.last.downloadedPages, 1);
    expect(await cache.getOfflinePages(7, 10), isNull);
  }

  test('real PNG is decoded; HTML, corrupt and truncated images rejected',
      () async {
    final file = File(p.join(directory.path, 'image'));
    await file.writeAsBytes(png);
    await OfflineChapterManager.validateImage(file);
    for (final bytes in [
      utf8.encode('<html>login</html>'),
      png.sublist(0, png.length - 5),
      [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        ...List.filled(50, 0),
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130
      ],
    ]) {
      await file.writeAsBytes(bytes);
      await expectLater(OfflineChapterManager.validateImage(file),
          throwsA(isA<LocalCacheException>()));
    }
  });

  test('restart resumes verified first page without GET', () async {
    await interrupted();
    final requests = <String>[];
    final cache = manager(MockClient((request) async {
      requests.add(request.url.path);
      return http.Response.bytes(png, 200);
    }));
    expect((await save(cache)).last.isComplete, isTrue);
    expect(requests, ['/page/1']);
    expect(await cache.getOfflinePages(7, 10), hasLength(2));
  });

  test('changed page URL sequence cannot reuse old pages', () async {
    await interrupted();
    final requests = <String>[];
    final cache = manager(MockClient((request) async {
      requests.add(request.url.path);
      return http.Response.bytes(png, 200);
    }));
    expect((await save(cache, urls: ['/new/0', '/page/1'])).last.isComplete,
        isTrue);
    expect(requests, ['/new/0', '/page/1']);
    requests.clear();
    expect((await save(cache, urls: ['/other/0', '/page/1'])).last.isComplete,
        isTrue);
    expect(requests, ['/other/0', '/page/1']);
  });

  test(
      'corrupt retained page is redownloaded, invalid response cannot complete',
      () async {
    await interrupted();
    final old = await Directory(p.join(directory.path, 'offline_manga'))
        .list(recursive: true)
        .where((e) => e.path.endsWith('0.jpg'))
        .first;
    await File(old.path).writeAsBytes(utf8.encode('<html>bad</html>'));
    var requests = 0;
    final cache = manager(MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    }));
    expect((await save(cache)).last.isComplete, isTrue);
    expect(requests, 2);
    final files = (await cache.getOfflinePages(7, 10))!;
    await files.first.writeAsBytes([1, 2, 3]);
    expect(await cache.getOfflinePages(7, 10), isNull);
    final bad = manager(
        MockClient((_) async => http.Response('<html>login</html>', 200)));
    expect((await save(bad)).last.isComplete, isFalse);
  });

  test('low space and unavailable capacity deny before GET', () async {
    var requests = 0;
    for (final capacity in [
      (String _) async => 0,
      (String _) async =>
          throw const LocalCacheException('storage_unavailable'),
    ]) {
      final cache = manager(MockClient((_) async {
        requests++;
        return http.Response.bytes(png, 200);
      }), availableBytes: capacity);
      expect((await save(cache)).last.isComplete, isFalse);
    }
    expect(requests, 0);
  });

  test('missing native channel fails closed before GET', () async {
    var requests = 0;
    final cache = manager(MockClient((_) async {
      requests++;
      return http.Response.bytes(png, 200);
    }), availableBytes: OfflineChapterManager.queryAndroidAvailableBytes);
    final events = await save(cache);
    expect(events.last.reasonCode, 'storage_unavailable');
    expect(events.last.cause, isA<LocalCacheException>());
    expect(requests, 0);
  });

  test('native channel capacity uses requested storage path', () async {
    const channel = MethodChannel('suwayomi/offline_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'availableBytes');
      expect(call.arguments, {'path': directory.path});
      return 123456;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    expect(
        await OfflineChapterManager.queryAndroidAvailableBytes(directory.path),
        123456);
  });

  test('mid-stream space drop stops writing and cleans only partial page',
      () async {
    var capacity = 1 << 40;
    Stream<List<int>> body() async* {
      yield png.sublist(0, 20);
      capacity = 0;
      yield png.sublist(20);
    }

    final cache = manager(
        MockClient.streaming(
            (_, __) async => http.StreamedResponse(body(), 200)),
        availableBytes: (_) async => capacity);
    final events = await save(cache);
    expect(events.last.reasonCode, 'insufficient_space');
    expect(await cache.getOfflinePages(7, 10), isNull);
    final files = await directory.list(recursive: true).toList();
    expect(files.where((f) => f.path.endsWith('.partial')), isEmpty);
    expect(files.where((f) => f.path.endsWith('.jpg')), isEmpty);
  });

  for (final clear in [false, true]) {
    test('resume cannot cross ${clear ? 'clear' : 'deletion'} generation',
        () async {
      await interrupted();
      final cache =
          manager(MockClient((_) async => http.Response.bytes(png, 200)));
      if (clear) {
        await cache.clearAllOfflineData();
      } else {
        await cache.deleteOfflineChapter(7, 10);
      }
      expect((await save(cache)).last.reasonCode, 'cache_excluded');
      await cache.allowAutomaticCache(7, 10);
      var requests = 0;
      final restarted = manager(MockClient((_) async {
        requests++;
        return http.Response.bytes(png, 200);
      }));
      expect((await save(restarted)).last.isComplete, isTrue);
      expect(requests, 2);
    });
  }

  test('concurrent same chapter attempts never mutate published page set',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final slow = manager(MockClient((_) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return http.Response.bytes(png, 200);
    }));
    final work = save(slow);
    await entered.future;
    final fast =
        manager(MockClient((_) async => http.Response.bytes(png, 200)));
    expect((await save(fast)).last.isComplete, isTrue);
    final firstFiles = (await fast.getOfflinePages(7, 10))!;
    release.complete();
    expect((await work).last.isComplete, isTrue);
    for (final file in firstFiles) {
      expect(await file.readAsBytes(), png);
    }
    expect(await fast.getOfflinePages(7, 10), hasLength(2));
  });
}
