import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../constants/endpoints.dart';
import '../../constants/enum.dart';
import '../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../../global_providers/global_providers.dart';
import '../extensions/custom_extensions.dart';
import '../logger/operation_log.dart';
import 'auth_headers.dart';
import 'auth_token_refresh.dart';

class AuthHttpClient extends http.BaseClient {
  AuthHttpClient({
    required this.inner,
    required this.serverUri,
    required this.headers,
    required this.refresh,
  });

  final http.Client inner;
  final Uri Function() serverUri;
  final Map<String, String> Function() headers;
  final Future<bool> Function() refresh;

  bool _isServer(Uri uri) {
    final server = serverUri();
    return uri.scheme == server.scheme &&
        uri.host == server.host &&
        uri.port == server.port;
  }

  void _authenticate(http.BaseRequest request) {
    request.headers
        .removeWhere((name, value) => name.toLowerCase() == 'authorization');
    request.headers.addAll(headers());
  }

  http.Request _copyReadRequest(http.BaseRequest request, Uri url) {
    final copy = http.Request(request.method, url)
      ..headers.addAll(request.headers)
      ..followRedirects = false
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;
    copy.headers
        .removeWhere((name, value) => name.toLowerCase() == 'authorization');
    if (_isServer(url)) _authenticate(copy);
    return copy;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_isServer(request.url)) return inner.send(request);
    final followRedirects = request.followRedirects;
    request.followRedirects = false;
    _authenticate(request);
    var response = await inner.send(request);
    final canRetry = (request.method == 'GET' || request.method == 'HEAD') &&
        request is http.Request &&
        request.bodyBytes.isEmpty;
    var current = request;
    var retried = false;
    var redirects = 0;
    while (true) {
      if (response.statusCode == 401 &&
          canRetry &&
          _isServer(current.url) &&
          !retried) {
        retried = true;
        var refreshed = false;
        var refreshCompleted = false;
        try {
          refreshed = await refresh();
          refreshCompleted = true;
        } finally {
          if (!refreshCompleted) await response.stream.drain<void>();
        }
        if (!refreshed) break;
        OperationLog.instance.record('MediaRequest',
            outcome: 'authentication_retry', httpStatus: 401);
        await response.stream.drain<void>();
        current = _copyReadRequest(current, current.url);
        response = await inner.send(current);
        continue;
      }
      final location = response.headers['location'];
      if (!followRedirects ||
          !canRetry ||
          ![301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null) {
        break;
      }
      await response.stream.drain<void>();
      if (redirects++ >= request.maxRedirects) {
        throw http.ClientException('Media redirect limit exceeded');
      }
      final target = Uri.tryParse(location);
      if (target == null) {
        throw http.ClientException('Invalid media redirect');
      }
      final url = current.url.resolveUri(target);
      if (url.scheme != 'http' && url.scheme != 'https') {
        throw http.ClientException('Unsupported media redirect scheme');
      }
      current = _copyReadRequest(current, url);
      response = await inner.send(current);
    }
    if (response.statusCode >= 400) {
      OperationLog.instance.record(
        'MediaRequest',
        outcome: 'http_error',
        httpStatus: response.statusCode,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

final serverMediaHttpClientProvider = Provider<http.Client>((ref) {
  final client = AuthHttpClient(
    inner: http.Client(),
    serverUri: () => Uri.parse(Endpoints.baseApi(
      baseUrl: ref.read(serverUrlProvider),
      port: ref.read(serverPortProvider),
      addPort: ref.read(serverPortToggleProvider).ifNull(),
      appendApiToUrl: false,
    )),
    headers: () => ref.read(serverAuthHeadersProvider),
    refresh: () => ref.read(authTypeKeyProvider) == AuthType.uiLogin
        ? renewUiLoginAccessToken(
            ref: ref, client: ref.read(graphQlClientProvider))
        : Future.value(false),
  );
  ref.onDispose(client.close);
  return client;
});
