import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/enum.dart';
import '../../features/settings/presentation/server/data/graphql/__generated__/login.graphql.dart';
import '../logger/auth_diagnostics.dart';
import '../logger/operation_log.dart';
import 'token_manager.dart';

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
  final refreshed = await _refresh(ref, authType, forward, request);
  if (refreshed) {
    yield* forward(request);
    return;
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
  final refreshed = await _refresh(ref, authType, forward, request);
  if (refreshed) {
    yield* forward(request);
    return;
  }
  yield* Stream<Response>.error(originalException);
}

Future<bool> _refresh(
  Ref ref,
  AuthType authType,
  NextLink forward,
  Request request,
) =>
    ref.read(authTokenRefresherProvider).refresh(() async {
      final refreshToken = ref.read(uiLoginRefreshTokenProvider);
      if (authType != AuthType.uiLogin ||
          refreshToken == null ||
          refreshToken.trim().isEmpty) {
        return false;
      }

      final refreshRequest = Request(
        operation: Operation(
          document: documentNodeMutationRefreshToken,
          operationName: 'RefreshToken',
        ),
        variables: {
          'input': {'refreshToken': refreshToken},
        },
        context: request.context,
      );

      final result = await AsyncValue.guard(() async {
        OperationLog.instance.record('RefreshToken', outcome: 'started');
        final refreshResponse = await forward(refreshRequest).first;
        if (refreshResponse.errors?.isNotEmpty == true) {
          OperationLog.instance.record('RefreshToken',
              outcome: 'graphql_error',
              errorCount: refreshResponse.errors!.length,
              authIssue:
                  classifyAuthIssue(refreshResponse.errors!.first.message));
          return false;
        }
        final data = refreshResponse.data;
        if (data == null) {
          throw StateError('Token refresh returned no data');
        }
        final accessToken =
            Mutation$RefreshToken.fromJson(data).refreshToken.accessToken;
        if (accessToken.trim().isEmpty) {
          throw StateError('Token refresh returned an empty access token');
        }

        if (ref.read(uiLoginRefreshTokenProvider) != refreshToken) {
          OperationLog.instance.record('RefreshToken', outcome: 'superseded');
          return false;
        }
        ref.read(uiLoginAccessTokenProvider.notifier).update(accessToken);
        OperationLog.instance.record('RefreshToken', outcome: 'completed');
        return true;
      });
      if (result.hasError) {
        final failure = result.error;
        final status = failure is HttpLinkServerException
            ? failure.response.statusCode
            : null;
        OperationLog.instance.record('RefreshToken',
            outcome: 'failed',
            errorType: failure.runtimeType.toString(),
            httpStatus: status,
            authIssue: status == 401 ? AuthIssue.unauthorized : null);
        return false;
      }
      return result.requireValue;
    });

bool _isAuthFailure(Response response) =>
    response.errors?.any((error) {
      final message = error.message.toLowerCase();
      return message.contains('unauthorized') ||
          message.contains('authentication');
    }) ??
    false;

bool _isAuthException(LinkException exception) {
  if (exception is! HttpLinkServerException) return false;
  final statusCode = exception.response.statusCode;
  return statusCode == 401;
}
