import 'package:graphql/client.dart';
import 'package:gql_http_link/gql_http_link.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/enum.dart';
import '../../global_providers/global_providers.dart';
import '../../graphql/__generated__/schema.graphql.dart';
import '../../utils/extensions/custom_extensions.dart';
import 'token_manager.dart';
import '../../features/settings/presentation/server/data/graphql/__generated__/login.graphql.dart';

Future<bool> refreshUiLoginToken({
  required Ref ref,
  required GraphQLClient client,
  required OperationException exception,
}) async {
  if (ref.read(authTypeKeyProvider) != AuthType.uiLogin ||
      !_isUnauthorized(exception)) {
    return false;
  }

  final refreshToken = ref.read(uiLoginRefreshTokenProvider);
  if (refreshToken.isBlank) return false;

  try {
    final refreshResult = await client
        .mutate$RefreshToken(
          Options$Mutation$RefreshToken(
            variables: Variables$Mutation$RefreshToken(
              input: Input$RefreshTokenInput(
                refreshToken: refreshToken!,
              ),
            ),
          ),
        )
        .getData((data) => data.refreshToken);

    final accessToken = refreshResult?.accessToken;
    if (accessToken.isNotBlank) {
      ref.read(uiLoginAccessTokenProvider.notifier).update(accessToken);
      return true;
    }
  } catch (_) {
    // Let the original request error propagate when refresh fails.
  }

  return false;
}

bool _isUnauthorized(OperationException exception) {
  final graphQlUnauthorized = exception.graphqlErrors.any((error) {
    final message = error.message.toLowerCase();
    return message.contains('unauthorized') || message.contains('forbidden');
  });
  if (graphQlUnauthorized) return true;

  final linkException = exception.linkException;
  if (linkException is ServerException) {
    final statusCode = linkException.parsedResponse?.context
        .entry<HttpLinkResponseContext>()
        ?.statusCode;
    return statusCode == 401 || statusCode == 403;
  }

  return false;
}
