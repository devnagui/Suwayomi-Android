import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/enum.dart';
import '../../features/settings/presentation/server/data/graphql/__generated__/login.graphql.dart';
import '../../global_providers/global_providers.dart';
import '../../graphql/__generated__/schema.graphql.dart';
import '../../utils/extensions/custom_extensions.dart';
import '../logger/operation_log.dart';
import 'token_manager.dart';

Future<bool> refreshUiLoginToken({
  required Ref ref,
  required GraphQLClient client,
  required OperationException exception,
}) async {
  if (ref.read(authTypeKeyProvider) != AuthType.uiLogin ||
      !_isUnauthorized(exception)) {
    return false;
  }
  return renewUiLoginAccessToken(ref: ref, client: client);
}

Future<bool> renewUiLoginAccessToken({
  required Ref ref,
  required GraphQLClient client,
}) =>
    ref.read(authTokenRefresherProvider).refresh(() async {
      final refreshToken = ref.read(uiLoginRefreshTokenProvider);
      if (refreshToken == null || refreshToken.trim().isEmpty) return false;

      final result = await AsyncValue.guard(() async {
        final refreshResult = await client
            .mutate$RefreshToken(
              Options$Mutation$RefreshToken(
                operationName: 'RefreshToken',
                variables: Variables$Mutation$RefreshToken(
                  input: Input$RefreshTokenInput(
                    refreshToken: refreshToken,
                  ),
                ),
              ),
            )
            .getData((data) => data.refreshToken);

        final accessToken = refreshResult?.accessToken;
        if (accessToken != null && accessToken.trim().isNotEmpty) {
          if (ref.read(uiLoginRefreshTokenProvider) != refreshToken ||
              ref.read(authTypeKeyProvider) != AuthType.uiLogin) {
            OperationLog.instance.record('RefreshToken', outcome: 'superseded');
            return false;
          }
          ref.read(uiLoginAccessTokenProvider.notifier).update(accessToken);
          return true;
        }
        throw StateError('Token refresh returned no access token');
      });
      if (result.hasError) {
        OperationLog.instance.record('RefreshToken',
            outcome: 'failed', errorType: result.error.runtimeType.toString());
        return false;
      }
      return result.requireValue;
    });

bool _isUnauthorized(OperationException exception) {
  final graphQlUnauthorized = exception.graphqlErrors.any((error) {
    final message = error.message.toLowerCase();
    return message.contains('unauthorized');
  });
  if (graphQlUnauthorized) return true;

  final linkException = exception.linkException;
  if (linkException is ServerException) {
    final statusCode = linkException.parsedResponse?.context
        .entry<HttpLinkResponseContext>()
        ?.statusCode;
    return statusCode == 401;
  }

  return false;
}
