import 'package:gql/language.dart' show gql;
import 'package:gql_exec/gql_exec.dart';
import 'package:gql_link/gql_link.dart';
import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/enum.dart';
import 'token_manager.dart';

const _refreshTokenMutation = r'''
mutation RefreshToken($input: RefreshTokenInput!) {
  refreshToken(input: $input) {
    accessToken
  }
}
''';

ErrorLink createAuthRefreshLink(Ref ref, AuthType authType) => ErrorLink(
      onGraphQLError: (request, forward, response) {
        if (!_isAuthFailure(response) ||
            request.operation.operationName == 'RefreshToken') {
          return null;
        }
        return _refreshAndRetry(ref, authType, request, forward, response);
      },
      onException: (request, forward, exception) {
        if (request.operation.operationName == 'RefreshToken' ||
            !_isAuthException(exception)) {
          return null;
        }
        return _refreshAndRetryException(
          ref, authType, request, forward, exception);
      },
    );

Stream<Response> _refreshAndRetry(
  Ref ref,
  AuthType authType,
  Request request,
  NextLink forward,
  Response originalResponse,
) async* {
  try {
    final refreshed = await _refresh(ref, authType, forward, request);
    if (refreshed) {
      yield* forward(request);
      return;
    }
  } catch (_) {
    // Keep the original response when refresh cannot be completed.
  }
  yield originalResponse;
}

Stream<Response> _refreshAndRetryException(
  Ref ref,
  AuthType authType,
  Request request,
  NextLink forward,
  LinkException originalException,
) async* {
  try {
    final refreshed = await _refresh(ref, authType, forward, request);
    if (refreshed) {
      yield* forward(request);
      return;
    }
  } catch (_) {
    // Keep the original exception when refresh cannot be completed.
  }
  yield* Stream<Response>.error(originalException);
}

Future<bool> _refresh(
  Ref ref,
  AuthType authType,
  NextLink forward,
  Request request,
) async {
  final refreshToken = ref.read(uiLoginRefreshTokenProvider);
  if (authType != AuthType.uiLogin || refreshToken == null) {
    return false;
  }

  final refreshRequest = Request(
    operation: Operation(
      document: gql(_refreshTokenMutation),
      operationName: 'RefreshToken',
    ),
    variables: {
      'input': {'refreshToken': refreshToken},
    },
    context: request.context,
  );

  final refreshResponse = await forward(refreshRequest).first;
  final accessToken = refreshResponse.data?['refreshToken']?['accessToken'];
  if (refreshResponse.errors?.isNotEmpty ?? true) {
    return false;
  }
  if (accessToken is! String || accessToken.isEmpty) return false;

  ref.read(uiLoginAccessTokenProvider.notifier).update(accessToken);
  return true;
}

bool _isAuthFailure(Response response) => response.errors?.any((error) {
      final message = error.message.toLowerCase();
      return message.contains('unauthorized') ||
          message.contains('forbidden') ||
          message.contains('authentication');
    }) ??
    false;

bool _isAuthException(LinkException exception) {
  if (exception is! HttpLinkServerException) return false;
  final statusCode = exception.response.statusCode;
  return statusCode == 401 || statusCode == 403;
}
