import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/enum.dart';
import '../../../../../../global_providers/global_providers.dart';
import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/network/token_manager.dart';
import '../../../../../../widgets/section_title.dart';
import '../credential_popup/credentials_popup.dart';
import '../ui_login/ui_login_popup.dart';
import 'auth_type/auth_type_tile.dart';

class AuthenticationSection extends ConsumerWidget {
  const AuthenticationSection({super.key});

  @override
  Widget build(context, ref) {
    final authType = ref.watch(authTypeKeyProvider);
    final accessToken = ref.watch(uiLoginAccessTokenProvider);
    final isLoggedIn =
        authType == AuthType.uiLogin && accessToken.isNotBlank;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: context.l10n.authentication),
        const AuthTypeTile(),
        if (authType == AuthType.basic)
          ListTile(
            leading: const Icon(Icons.password_rounded),
            title: Text(context.l10n.credentials),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => const CredentialsPopup(),
              );
            },
          ),
        if (authType == AuthType.uiLogin) ...[
          ListTile(
            leading: Icon(
              isLoggedIn ? Icons.login_rounded : Icons.login_outlined,
            ),
            title: Text(context.l10n.authTypeUiLogin),
            subtitle: Text(
              isLoggedIn
                  ? context.l10n.loggedIn
                  : context.l10n.loggedOut,
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => const UiLoginPopup(),
              );
            },
          ),
          if (isLoggedIn)
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: Text(context.l10n.logout),
              onTap: () {
                ref
                    .read(uiLoginAccessTokenProvider.notifier)
                    .update(null);
                ref
                    .read(uiLoginRefreshTokenProvider.notifier)
                    .update(null);
              },
            ),
        ],
      ],
    );
  }
}
