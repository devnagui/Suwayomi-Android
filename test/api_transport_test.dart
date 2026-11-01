import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/ast.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tachidesk_sorayomi/src/constants/db_keys.dart';
import 'package:tachidesk_sorayomi/src/constants/enum.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/downloads/data/downloads_settings_repository.dart';
import 'package:tachidesk_sorayomi/src/features/settings/presentation/library/data/library_settings_repository.dart';
import 'package:tachidesk_sorayomi/src/global_providers/global_providers.dart';
import 'package:tachidesk_sorayomi/src/utils/network/auth_refresh_link.dart';
import 'package:tachidesk_sorayomi/src/utils/network/token_manager.dart';

const userSettingsData = {
  '__typename': 'UserSettingsType',
  'updateMangas': true,
  'excludeCompleted': true,
  'excludeNotStarted': false,
  'excludeUnreadChapters': true,
  'autoDownloadNewChapters': true,
  'autoDownloadNewChaptersLimit': 5,
  'excludeEntryWithUnreadChapters': false,
};

Future<ProviderContainer> containerFor({
  AuthType authType = AuthType.uiLogin,
  int? port,
  HiveStore? store,
}) async {
  SharedPreferences.setMockInitialValues({
    DBKeys.authType.name: authType.index,
    DBKeys.uiLoginAccessToken.name: 'test-access-token',
    DBKeys.uiLoginRefreshToken.name: 'test-refresh-token',
    if (port != null) DBKeys.serverUrl.name: 'http://127.0.0.1',
    if (port != null) DBKeys.serverPort.name: port,
    if (port != null) DBKeys.basicCredentials.name: 'Basic dGVzdDp0ZXN0',
  });
  final preferences = await SharedPreferences.getInstance();
  return ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(preferences),
    if (store != null) hiveStoreProvider.overrideWithValue(store),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('refresh without an errors property updates the token and retries once',
      () async {
    final container = await containerFor();
    addTearDown(container.dispose);
    var requests = 0;
    var refreshes = 0;
    final clientProvider = Provider((ref) => GraphQLClient(
          link: createAuthRefreshLink(ref, AuthType.uiLogin).concat(
            Link.function((request, [forward]) async* {
              if (request.operation.operationName == 'RefreshToken') {
                refreshes++;
                expect(request.variables['input'],
                    {'refreshToken': 'test-refresh-token'});
                yield Response(response: const {}, data: {
                  '__typename': 'Mutation',
                  'refreshToken': {
                    '__typename': 'RefreshTokenPayload',
                    'clientMutationId': null,
                    'accessToken': 'new-access-token',
                  },
                });
              } else {
                requests++;
                yield requests == 1
                    ? Response(
                        response: const {},
                        errors: [GraphQLError(message: 'Unauthorized')])
                    : Response(
                        response: const {}, data: {'__typename': 'Query'});
              }
            }),
          ),
          cache: GraphQLCache(),
        ));
    final result = await container.read(clientProvider).query(
          QueryOptions(
            document: gql('query Test { __typename }'),
            fetchPolicy: FetchPolicy.networkOnly,
          ),
        );
    expect(result.hasException, isFalse);
    expect(requests, 2);
    expect(refreshes, 1);
    expect(container.read(uiLoginAccessTokenProvider), 'new-access-token');
  });

  for (final message in ['Forbidden', 'Unauthorized']) {
    test('$message remains visible when refresh is not permitted or fails',
        () async {
      final container = await containerFor();
      addTearDown(container.dispose);
      var refreshes = 0;
      var requests = 0;
      final clientProvider = Provider((ref) => GraphQLClient(
            link: createAuthRefreshLink(ref, AuthType.uiLogin).concat(
              Link.function((request, [forward]) async* {
                if (request.operation.operationName == 'RefreshToken') {
                  refreshes++;
                  yield Response(
                      response: const {},
                      errors: [GraphQLError(message: 'Token revoked')]);
                } else {
                  requests++;
                  yield Response(
                      response: const {},
                      errors: [GraphQLError(message: message)]);
                }
              }),
            ),
            cache: GraphQLCache(),
          ));
      final result = await container.read(clientProvider).query(
            QueryOptions(
              document: gql('query Test { __typename }'),
              fetchPolicy: FetchPolicy.networkOnly,
            ),
          );
      expect(result.exception?.graphqlErrors.single.message, message);
      expect(requests, 1);
      expect(refreshes, message == 'Unauthorized' ? 1 : 0);
    });
  }

  test('library and download preferences use setUserSettings', () async {
    final requests = <Request>[];
    final client = GraphQLClient(
      link: Link.function((request, [forward]) async* {
        requests.add(request);
        yield Response(response: const {}, data: {
          '__typename': 'Mutation',
          'setUserSettings': {
            '__typename': 'SetUserSettingsPayload',
            'userSettings': userSettingsData,
          },
        });
      }),
      cache: GraphQLCache(),
    );
    final library = LibrarySettingsRepository(client);
    final downloads = DownloadsSettingsRepository(client);
    expect((await library.updateMangaMetaData(true))?.updateMangas, isTrue);
    expect(
        (await library.toggleExcludeCompleted(true))?.excludeCompleted, isTrue);
    expect((await library.toggleExcludeNotStarted(false))?.excludeNotStarted,
        isFalse);
    expect(
        (await library.toggleExcludeUnreadChapters(true))
            ?.excludeUnreadChapters,
        isTrue);
    expect(
        (await downloads.toggleAutoDownloadNewChapters(true))
            ?.autoDownloadNewChapters,
        isTrue);
    expect(
        (await downloads.updateAutoDownloadNewChaptersLimit(5))
            ?.autoDownloadNewChaptersLimit,
        5);
    expect(
        (await downloads.toggleExcludeEntryWithUnreadChapters(false))
            ?.excludeEntryWithUnreadChapters,
        isFalse);
    expect(requests, hasLength(7));
    for (final request in requests) {
      final fields = request.operation.document.definitions
          .whereType<OperationDefinitionNode>()
          .single
          .selectionSet
          .selections
          .whereType<FieldNode>()
          .where((field) => field.name.value != '__typename');
      expect(fields.single.name.value, 'setUserSettings');
    }
  });

  for (final authType in [AuthType.uiLogin, AuthType.basic, AuthType.none]) {
    test('WebSocket $authType sends the server authentication contract',
        () async {
      final directory = await Directory.systemTemp.createTemp('sorayomi-api-');
      final store = await HiveStore.open(
        boxName: 'api-${authType.name}',
        path: directory.path,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final init = Completer<Map<String, dynamic>>();
      String? authorization;
      WebSocket? socket;
      final connections = server.listen((request) async {
        authorization = request.headers.value(HttpHeaders.authorizationHeader);
        socket = await WebSocketTransformer.upgrade(request,
            protocolSelector: (protocols) => 'graphql-transport-ws');
        socket!.listen((message) {
          final value = jsonDecode(message as String) as Map<String, dynamic>;
          if (value['type'] == 'connection_init') {
            init.complete(value);
            socket!.add(jsonEncode({'type': 'connection_ack'}));
          }
        });
      });
      final container = await containerFor(
        authType: authType,
        port: server.port,
        store: store,
      );
      final clientListener =
          container.listen(graphQlSubscriptionClientProvider, (_, __) {});
      final client = clientListener.read();
      final subscription = client
          .subscribe(SubscriptionOptions(
            document: gql('subscription Test { __typename }'),
          ))
          .listen((_) {});
      try {
        final message = await init.future.timeout(const Duration(seconds: 5));
        expect(message['payload'], {
          if (authType == AuthType.uiLogin)
            'Authorization': 'test-access-token',
        });
        expect(authorization,
            authType == AuthType.basic ? 'Basic dGVzdDp0ZXN0' : isNull);
      } finally {
        await subscription.cancel();
        clientListener.close();
        container.dispose();
        await socket?.close();
        await connections.cancel();
        await server.close(force: true);
        await store.box.close();
        await directory.delete(recursive: true);
      }
    });
  }
}
