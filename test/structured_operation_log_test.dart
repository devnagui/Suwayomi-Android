import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:graphql/client.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/logger_link.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/mutation_cache.dart';

void main() {
  test('JSON export contains versioned, correlated, typed failure data only',
      () {
    final log = OperationLog()..setAppInfo('0.6.9', '2006');
    addTearDown(log.dispose);
    log.record(
      'OfflineChapterCache',
      outcome: 'failed',
      stage: 'device_cache',
      chapterId: 4991,
      mangaId: 225,
      attempt: 2,
      httpStatus: 503,
      reasonCode: 'http_error',
      error: const HttpException('Bearer secret-token https://private.test'),
      stackTrace: StackTrace.fromString(
        '#0      cache (package:tachidesk_sorayomi/src/utils/network/local_download_queue.dart:20:3)\n'
        '#1      hidden (https://private.test/?token=secret-token:1:2)\n'
        '#2      hidden (file:///private/secret-token.dart:1:2)\n',
      ),
    );
    final exported = log.exportJson();
    final document = jsonDecode(exported) as Map<String, dynamic>;
    expect(document['schemaVersion'], 1);
    expect(document['appVersion'], '0.6.9');
    expect(document['buildNumber'], '2006');
    final event = (document['events'] as List).single as Map<String, dynamic>;
    expect(event['stage'], 'device_cache');
    expect(event['severity'], 'error');
    expect(event['chapterId'], 4991);
    expect(event['attempt'], 2);
    expect(event['httpStatus'], 503);
    expect(event['exception'], {
      'type': 'HttpException',
      'reasonCode': 'http_error',
      'stack': [
        'package:tachidesk_sorayomi/src/utils/network/local_download_queue.dart:20:3'
      ],
    });
    for (final sensitive in ['secret-token', 'private.test', 'file://', 'Bearer']) {
      expect(exported, isNot(contains(sensitive)));
    }
  });

  test('ordinary event churn does not erase the bounded failure history', () {
    final log = OperationLog(capacity: 3);
    addTearDown(log.dispose);
    log.record('ServerDownload', outcome: 'failed', chapterId: 4991,
        state: 'ERROR', reasonCode: 'server_reason_unavailable');
    for (var i = 0; i < 600; i++) {
      log.record('GetDownloadStatus', outcome: 'response');
    }
    var document = jsonDecode(log.exportJson()) as Map<String, dynamic>;
    expect(document['events'], hasLength(3));
    expect((document['recentFailures'] as List).single['chapterId'], 4991);
    for (var i = 0; i < 60; i++) {
      log.record('ServerDownload', outcome: 'failed', chapterId: i);
    }
    document = jsonDecode(log.exportJson()) as Map<String, dynamic>;
    expect(document['recentFailures'], hasLength(50));
    log.clear();
    document = jsonDecode(log.exportJson()) as Map<String, dynamic>;
    expect(document['events'], isEmpty);
    expect(document['recentFailures'], isEmpty);
  });

  test('a chapter-metadata batch does not flood or evict download diagnostics',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('structured-metadata-');
    addTearDown(() => directory.delete(recursive: true));
    OperationLog.instance.clear();
    addTearDown(OperationLog.instance.clear);
    OperationLog.instance.record('ServerDownload',
        outcome: 'failed', chapterId: 4991);
    final cache = MutationCache.forDirectory(directory);
    for (var i = 0; i < 501; i++) {
      await cache.put('chapter_$i', {'id': i});
    }
    expect(OperationLog.instance.value, hasLength(1));
    expect(OperationLog.instance.value.single, contains('chapterId=4991'));
  });

  test('subscription timing is elapsed lifetime, with IDs on every event',
      () async {
    final log = OperationLog();
    addTearDown(log.dispose);
    final request = Request(
      operation: Operation(
        document: parseString('subscription Updates { __typename }'),
        operationName: 'Updates',
      ),
      variables: const {'input': {'chapterId': 4991}},
    );
    await LoggerLink(operationLog: log)
        .request(request,
            (_) => Stream.value(Response(response: const {}, data: const {})))
        .single;
    final events =
        (jsonDecode(log.exportJson()) as Map<String, dynamic>)['events'] as List;
    expect(events, hasLength(2));
    expect(events[0]['requestId'], events[1]['requestId']);
    expect(events[1]['chapterId'], 4991);
    expect(events[1]['stage'], 'subscription');
    expect(events[1]['outcome'], 'event');
    expect(events[1], contains('elapsedMs'));
    expect(events[1], isNot(contains('durationMs')));
  });

  test('known server exceptions are classified without exporting their message',
      () async {
    final log = OperationLog();
    addTearDown(log.dispose);
    final request = Request(operation: Operation(
      document: parseString('query Pages { __typename }'),
      operationName: 'Pages',
    ));
    await LoggerLink(operationLog: log).request(request, (_) => Stream.value(
      Response(response: const {}, errors: [
        GraphQLError(message:
            'Timed out waiting for WebView after 1m https://private.test secret-token'),
      ]),
    )).single;
    final event = log.latestEvent('Pages')!;
    expect(event['reasonCode'], 'server_webview_timeout');
    expect(event['errorType'], 'GraphQLError');
    expect(log.exportJson(), isNot(contains('private.test')));
    expect(log.exportJson(), isNot(contains('secret-token')));
  });
}
