import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/general/cache_recovery_section.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/server/widget/ui_login/ui_login_popup.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/l10n/generated/app_localizations.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/auth_diagnostics.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/logger_link.dart';
import 'package:tachidesk_sorayomi/src/utils/logger/operation_log.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_headers.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_http_client.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_refresh_link.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_token_refresh.dart';
import 'package:tachidesk_sorayomi/src/utils/network/offline_chapter_manager.dart';
import 'package:tachidesk_sorayomi/src/utils/network/token_manager.dart';

class NativeHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => OperationLog.instance.clear());

  testWidgets(
      'blank login tokens remain a visible error and do not replace credentials',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final client = GraphQLClient(
      link: Link.function((request, [forward]) async* {
        yield Response(response: const {}, data: {
          '__typename': 'Mutation',
          'login': {
            '__typename': 'LoginPayload',
            'accessToken': '   ',
            'refreshToken': 'refresh-token',
            'clientMutationId': null,
          },
        });
      }),
      cache: GraphQLCache(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        uiLoginClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: UiLoginPopup()),
      ),
    ));
    await tester.enterText(find.byType(TextFormField).at(0), 'test-user');
    await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('Login returned empty tokens'), findsOneWidget);
    expect(preferences.getString(DBKeys.uiLoginAccessToken.name), isNull);
    expect(preferences.getString(DBKeys.uiLoginRefreshToken.name), isNull);
    expect(find.widgetWithText(TextButton, 'Copy error'), findsOneWidget);
  });

  test('HEAD media renewal replays HEAD once without a request body', () async {
    var sends = 0;
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        expect(request.method, 'HEAD');
        expect(request.bodyBytes, isEmpty);
        return http.Response('', ++sends == 1 ? 401 : 200);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async => true,
    );
    addTearDown(client.close);
    expect(
        (await client.head(Uri.parse('https://server.test/image'))).statusCode,
        200);
    expect(sends, 2);
  });

  test('unexpected refresh failures release the response and remain errors',
      () async {
    var drained = false;
    final failure = StateError('Refresh service unavailable');
    final client = AuthHttpClient(
      inner:
          MockClient.streaming((request, body) async => http.StreamedResponse(
                Stream.value([1, 2, 3]).map((chunk) {
                  drained = true;
                  return chunk;
                }),
                401,
              )),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async => throw failure,
    );
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://server.test/image')),
        throwsA(same(failure)));
    expect(drained, isTrue);
  });

  test('an old refresh cannot overwrite a newly signed-in account', () async {
    SharedPreferences.setMockInitialValues({
      DBKeys.authType.name: AuthType.uiLogin.index,
      DBKeys.uiLoginRefreshToken.name: 'old-refresh',
      DBKeys.uiLoginAccessToken.name: 'old-access',
    });
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
    ]);
    addTearDown(container.dispose);
    final ready = Completer<void>();
    final started = Completer<void>();
    final client = GraphQLClient(
      link: Link.function((request, [forward]) async* {
        started.complete();
        await ready.future;
        yield Response(response: const {}, data: {
          '__typename': 'Mutation',
          'refreshToken': {
            '__typename': 'RefreshTokenPayload',
            'accessToken': 'stale-account-access',
            'clientMutationId': null,
          },
        });
      }),
      cache: GraphQLCache(),
    );
    final provider = Provider(
        (ref) => () => renewUiLoginAccessToken(ref: ref, client: client));
    final pending = container.read(provider)();
    await started.future;
    container
        .read(uiLoginRefreshTokenProvider.notifier)
        .update('new-account-refresh');
    container
        .read(uiLoginAccessTokenProvider.notifier)
        .update('new-account-access');
    ready.complete();
    expect(await pending, isFalse);
    expect(container.read(uiLoginAccessTokenProvider), 'new-account-access');
    expect(OperationLog.instance.exportText(), contains('superseded'));
  });

  for (final target in [
    'https://server.test/next-image',
    'https://images.server.test/image',
    'https://server.test:8443/image',
    'http://server.test/image',
  ]) {
    test('redirect to $target follows exact-origin credential rules', () async {
      var sends = 0;
      final client = AuthHttpClient(
        inner: MockClient((request) async {
          sends++;
          expect(request.followRedirects, isFalse);
          if (sends == 1) {
            expect(request.headers['Authorization'], 'Bearer token');
            return http.Response('', 302, headers: {'location': target});
          }
          expect(request.url.toString(), target);
          expect(
              request.headers['Authorization'],
              target == 'https://server.test/next-image'
                  ? 'Bearer token'
                  : isNull);
          return http.Response('image', 200);
        }),
        serverUri: () => Uri.parse('https://server.test'),
        headers: () => {'Authorization': 'Bearer token'},
        refresh: () async => false,
      );
      addTearDown(client.close);
      expect((await client.get(Uri.parse('https://server.test/image'))).body,
          'image');
      expect(sends, 2);
    });
  }

  test('redirect loops fail explicitly at the configured limit', () async {
    var sends = 0;
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        sends++;
        return http.Response('', 302, headers: {'location': '/image'});
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async => false,
    );
    addTearDown(client.close);
    await expectLater(
        client.send(http.Request('GET', Uri.parse('https://server.test/image'))
          ..maxRedirects = 2),
        throwsA(isA<http.ClientException>()));
    expect(sends, 3);
  });

  test(
      'GraphQL and media expiry share renewal and keep HTTP clients stable',
      () => HttpOverrides.runWithHttpOverrides(() async {
            final directory =
                await Directory.systemTemp.createTemp('sorayomi-auth-http-');
            final store = await HiveStore.open(
                boxName: 'auth-http', path: directory.path);
            final server =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final failuresReady = Completer<void>();
            var failures = 0;
            var refreshes = 0;
            final connections = server.listen((request) async {
              final authorization =
                  request.headers.value(HttpHeaders.authorizationHeader);
              if (request.uri.path == '/api/graphql') {
                final body = jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>;
                request.response.headers.contentType = ContentType.json;
                if (body['operationName'] == 'RefreshToken') {
                  refreshes++;
                  expect(authorization, isNull);
                  await failuresReady.future
                      .timeout(const Duration(seconds: 5));
                  request.response.write(jsonEncode({
                    'data': {
                      '__typename': 'Mutation',
                      'refreshToken': {
                        '__typename': 'RefreshTokenPayload',
                        'accessToken': 'new-token',
                        'clientMutationId': null,
                      },
                    },
                  }));
                } else if (authorization == 'Bearer old-token') {
                  if (++failures == 2) failuresReady.complete();
                  request.response.write(jsonEncode({
                    'errors': [
                      {'message': 'Unauthorized'}
                    ]
                  }));
                } else {
                  expect(authorization, 'Bearer new-token');
                  request.response.write(jsonEncode({
                    'data': {'__typename': 'Query'}
                  }));
                }
              } else {
                if (authorization == 'Bearer old-token') {
                  if (++failures == 2) failuresReady.complete();
                  request.response.statusCode = 401;
                } else {
                  expect(authorization, 'Bearer new-token');
                  request.response.add([1, 2, 3]);
                }
              }
              await request.response.close();
            });
            SharedPreferences.setMockInitialValues({
              DBKeys.authType.name: AuthType.uiLogin.index,
              DBKeys.serverUrl.name: 'http://127.0.0.1',
              DBKeys.serverPort.name: server.port,
              DBKeys.uiLoginAccessToken.name: 'old-token',
              DBKeys.uiLoginRefreshToken.name: 'refresh-token',
            });
            final preferences = await SharedPreferences.getInstance();
            final container = ProviderContainer(overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              hiveStoreProvider.overrideWithValue(store),
            ]);
            final listener =
                container.listen(graphQlClientProvider, (_, __) {});
            try {
              final gqlClient = container.read(graphQlClientProvider);
              final mediaClient = container.read(serverMediaHttpClientProvider);
              final result = gqlClient.query(QueryOptions(
                document: gql('query Test { __typename }'),
                operationName: 'Test',
                fetchPolicy: FetchPolicy.networkOnly,
              ));
              final media = mediaClient
                  .get(Uri.parse('http://127.0.0.1:${server.port}/api/page'));
              expect(
                  (await result.timeout(const Duration(seconds: 8)))
                      .hasException,
                  isFalse);
              expect(
                  (await media.timeout(const Duration(seconds: 8))).statusCode,
                  200);
              await container.pump();
              expect(refreshes, 1);
              expect(container.read(uiLoginAccessTokenProvider), 'new-token');
              expect(
                  identical(container.read(graphQlClientProvider), gqlClient),
                  isTrue);
              expect(
                  identical(container.read(serverMediaHttpClientProvider),
                      mediaClient),
                  isTrue);
              expect(OperationLog.instance.exportText(),
                  isNot(contains('refresh-token')));
            } finally {
              listener.close();
              container.dispose();
              await connections.cancel();
              await server.close(force: true);
              await store.box.close();
              await directory.delete(recursive: true);
            }
          }, NativeHttpOverrides()));

  test(
      'failed retried GraphQL requests do not revert to the original auth error',
      () async {
    SharedPreferences.setMockInitialValues({
      DBKeys.authType.name: AuthType.uiLogin.index,
      DBKeys.uiLoginRefreshToken.name: 'refresh-token',
    });
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
    ]);
    addTearDown(container.dispose);
    var sends = 0;
    final provider = Provider((ref) => GraphQLClient(
          link: createAuthRefreshLink(ref, AuthType.uiLogin)
              .concat(Link.function((request, [forward]) async* {
            if (request.operation.operationName == 'RefreshToken') {
              yield Response(response: const {}, data: {
                '__typename': 'Mutation',
                'refreshToken': {
                  '__typename': 'RefreshTokenPayload',
                  'clientMutationId': null,
                  'accessToken': 'new-token',
                },
              });
            } else if (++sends == 1) {
              yield Response(
                  response: const {},
                  errors: [GraphQLError(message: 'Unauthorized')]);
            } else {
              throw const ServerException(
                  originalException: 'Retry network failure');
            }
          })),
          cache: GraphQLCache(),
        ));
    final result = await container.read(provider).query(QueryOptions(
          document: gql('query Test { __typename }'),
          fetchPolicy: FetchPolicy.networkOnly,
        ));
    expect(result.exception?.linkException, isA<ServerException>());
    expect(result.exception?.graphqlErrors, isEmpty);
    expect(sends, 2);
  });

  test('JWT, legacy Basic and signed-out media headers are explicit', () {
    expect(
        serverAuthHeaders(
            authType: AuthType.uiLogin, accessToken: 'access-token'),
        {'Authorization': 'Bearer access-token'});
    expect(
        serverAuthHeaders(
            authType: AuthType.basic, basicCredentials: 'Basic dGVzdA=='),
        {'Authorization': 'Basic dGVzdA=='});
    expect(
        serverAuthHeaders(authType: AuthType.none, accessToken: 'access-token'),
        isEmpty);
    expect(serverAuthHeaders(authType: AuthType.uiLogin, accessToken: '   '),
        isEmpty);
    expect(serverAuthHeaders(authType: AuthType.uiLogin), isEmpty);
  });

  test('image-file service receives JWT and retries a stale token once',
      () async {
    var token = 'old-token';
    var sends = 0;
    var refreshes = 0;
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        sends++;
        expect(request.headers['Authorization'],
            sends == 1 ? 'Bearer old-token' : 'Bearer new-token');
        return http.Response.bytes([1, 2, 3], sends == 1 ? 401 : 200);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer $token'},
      refresh: () async {
        refreshes++;
        token = 'new-token';
        return true;
      },
    );
    addTearDown(client.close);
    final response = await HttpFileService(httpClient: client).get(
      'https://server.test/api/cover',
      headers: {'authorization': 'obsolete-header'},
    );
    expect(response.statusCode, 200);
    expect(await response.content.toList(), isNotEmpty);
    expect(sends, 2);
    expect(refreshes, 1);
    expect(
        OperationLog.instance.exportText(), contains('authentication_retry'));
    expect(OperationLog.instance.exportText(), isNot(contains('old-token')));
  });

  for (final status in [401, 403]) {
    test('failed media auth HTTP $status is preserved without a retry loop',
        () async {
      var sends = 0;
      var refreshes = 0;
      final client = AuthHttpClient(
        inner: MockClient((request) async {
          sends++;
          return http.Response('denied', status);
        }),
        serverUri: () => Uri.parse('https://server.test'),
        headers: () => {'Authorization': 'Bearer token'},
        refresh: () async {
          refreshes++;
          return false;
        },
      );
      addTearDown(client.close);
      expect(
          (await client.get(Uri.parse('https://server.test/api/page')))
              .statusCode,
          status);
      expect(sends, 1);
      expect(refreshes, status == 401 ? 1 : 0);
      expect(
          OperationLog.instance.exportText(), contains('httpStatus=$status'));
    });
  }

  test('a still-rejected refreshed token retries only once', () async {
    var sends = 0;
    var refreshes = 0;
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        sends++;
        return http.Response('denied', 401);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async {
        refreshes++;
        return true;
      },
    );
    addTearDown(client.close);
    expect(
        (await client.get(Uri.parse('https://server.test/api/page')))
            .statusCode,
        401);
    expect(sends, 2);
    expect(refreshes, 1);
  });

  test('media POST is never replayed after an authentication error', () async {
    var sends = 0;
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        sends++;
        return http.Response('denied', 401);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async => throw StateError('Must not replay POST'),
    );
    addTearDown(client.close);
    await client.post(Uri.parse('https://server.test/api/action'),
        body: 'test');
    expect(sends, 1);
  });

  test('server credentials are not injected into another origin', () async {
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        expect(
            request.headers.keys
                .where((name) => name.toLowerCase() == 'authorization'),
            isEmpty);
        return http.Response('public', 200);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => {'Authorization': 'Bearer token'},
      refresh: () async =>
          throw StateError('Must not refresh a foreign request'),
    );
    addTearDown(client.close);
    await client.get(Uri.parse('https://cdn.test/image'));
    await client.get(Uri.parse('https://server.test:8443/image'));
    await client.get(Uri.parse('http://server.test/image'));
  });

  test(
      'signed-out requests discard obsolete authorization on the server origin',
      () async {
    final client = AuthHttpClient(
      inner: MockClient((request) async {
        expect(
            request.headers.keys
                .where((name) => name.toLowerCase() == 'authorization'),
            isEmpty);
        return http.Response('public', 200);
      }),
      serverUri: () => Uri.parse('https://server.test'),
      headers: () => const {},
      refresh: () async => false,
    );
    addTearDown(client.close);
    await client.get(Uri.parse('https://server.test/image'),
        headers: {'authorization': 'Bearer stale-token'});
  });

  test('concurrent refresh attempts share a single in-flight request',
      () async {
    final refresher = AuthTokenRefresher();
    final ready = Completer<bool>();
    var refreshes = 0;
    Future<bool> refresh() => refresher.refresh(() {
          refreshes++;
          return ready.future;
        });
    final first = refresh();
    final second = refresh();
    ready.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(refreshes, 1);
    expect(await refresher.refresh(() async => false), isFalse);
  });

  test(
      'offline pages use current JWT headers without persisting tokens in files',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('sorayomi-jwt-offline-');
    addTearDown(() => directory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      DBKeys.authType.name: AuthType.uiLogin.index,
      DBKeys.serverUrl.name: 'http://server.test',
      DBKeys.serverPortToggle.name: false,
      DBKeys.uiLoginAccessToken.name: 'first-token',
    });
    final preferences = await SharedPreferences.getInstance();
    late ProviderContainer container;
    var requests = 0;
    final inner = MockClient((request) async {
      requests++;
      expect(request.headers['Authorization'],
          requests == 1 ? 'Bearer first-token' : 'Bearer second-token');
      if (requests == 1) {
        container
            .read(uiLoginAccessTokenProvider.notifier)
            .update('second-token');
      }
      return http.Response.bytes([4, 5, 6], 200);
    });
    final client = AuthHttpClient(
      inner: inner,
      serverUri: () => Uri.parse('http://server.test'),
      headers: () => container.read(serverAuthHeadersProvider),
      refresh: () async => false,
    );
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      serverMediaHttpClientProvider.overrideWithValue(client),
    ]);
    addTearDown(container.dispose);
    addTearDown(client.close);
    final managerProvider = Provider((ref) => OfflineChapterManager(
          ref,
          documentsDirectory: () async => directory,
        ));
    final manager = container.read(managerProvider);
    final result = await manager.downloadChapter(
      mangaId: 37,
      chapterId: 12,
      pageUrls: ['/api/page/0', '/api/page/1'],
    ).toList();
    expect(result.last.isComplete, isTrue);
    expect(requests, 2);
    expect(await manager.isChapterAvailableOffline(37, 12), isTrue);
    final pages = await manager.getOfflinePages(37, 12);
    expect(await pages!.first.readAsBytes(), [4, 5, 6]);
    expect(preferences.getString('offline_chapters_metadata'),
        isNot(contains('first-token')));
  });

  test(
      'known auth errors classify safely and visible errors redact credentials',
      () {
    expect(classifyAuthIssue('Cannot login while already logged-in'),
        AuthIssue.alreadyAuthenticated);
    expect(classifyAuthIssue('Incorrect username or password.'),
        AuthIssue.invalidCredentials);
    expect(classifyAuthIssue('Unauthorized'), AuthIssue.unauthorized);
    final safe = redactAuthError(
        'error password-value Bearer eyJaa.bbb.ccc refresh-value', [
      'password-value',
      'refresh-value',
    ]);
    expect(safe, isNot(contains('password-value')));
    expect(safe, isNot(contains('refresh-value')));
    expect(safe, isNot(contains('eyJaa.bbb.ccc')));
    final log = OperationLog();
    addTearDown(log.dispose);
    log.record('Login',
        outcome: 'graphql_error',
        authIssue: classifyAuthIssue('Incorrect username or password.'));
    expect(log.exportText(), contains('authIssue=invalidCredentials'));
    expect(log.exportText(), isNot(contains('Incorrect username')));
  });

  testWidgets('login errors stay visible and can be copied on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final client = GraphQLClient(
      link: LoggerLink().concat(Link.function((request, [forward]) async* {
        expect(request.operation.operationName, 'Login');
        yield Response(response: const {}, errors: [
          GraphQLError(message: 'Cannot login while already logged-in'),
        ]);
      })),
      cache: GraphQLCache(),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        uiLoginClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: UiLoginPopup()),
      ),
    ));
    await tester.enterText(find.byType(TextFormField).at(0), 'test-user');
    await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('This endpoint already authenticates'),
        findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Copy error'));
    await tester.pumpAndSettle();
    expect(copied, contains('UI Login'));
    expect(copied, isNot(contains('test-password')));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Operation log'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('authIssue=alreadyAuthenticated'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Copy log'));
    await tester.pumpAndSettle();
    expect(copied, contains('Login'));
    expect(copied, isNot(contains('test-password')));
  });

  testWidgets('compact log access works without a logged-in server',
      (tester) async {
    final log = OperationLog();
    addTearDown(log.dispose);
    log.record('Login', outcome: 'http_error', httpStatus: 401);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          appBar: AppBar(actions: [
        OperationLogTile(compact: true, operationLog: log),
      ])),
    ));
    await tester.tap(find.byTooltip('Operation log'));
    await tester.pumpAndSettle();
    expect(find.textContaining('httpStatus=401'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Export operation log'),
        findsOneWidget);
  });
}
