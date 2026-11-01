import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/enum.dart';
import '../../features/settings/presentation/server/widget/credential_popup/credentials_popup.dart';
import '../../global_providers/global_providers.dart';
import 'token_manager.dart';

Map<String, String> serverAuthHeaders({
  required AuthType? authType,
  String? basicCredentials,
  String? accessToken,
}) {
  final basic = basicCredentials?.trim();
  final token = accessToken?.trim();
  if (authType == AuthType.basic && basic?.isNotEmpty == true) {
    return {'Authorization': basic!};
  }
  if (authType == AuthType.uiLogin && token?.isNotEmpty == true) {
    return {'Authorization': 'Bearer $token'};
  }
  return const {};
}

final serverAuthHeadersProvider =
    Provider<Map<String, String>>((ref) => serverAuthHeaders(
          authType: ref.watch(authTypeKeyProvider),
          basicCredentials: ref.watch(credentialsProvider),
          accessToken: ref.watch(uiLoginAccessTokenProvider),
        ));
