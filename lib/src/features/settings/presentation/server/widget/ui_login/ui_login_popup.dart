// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/endpoints.dart';
import '../../../../../../constants/db_keys.dart';
import '../../../../../../global_providers/global_providers.dart';
import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/network/token_manager.dart';
import '../../../../../../utils/network/timeout_http_client.dart';
import '../../../../../../widgets/popup_widgets/pop_button.dart';
import '../client/server_port_tile/server_port_tile.dart';
import '../client/server_url_tile/server_url_tile.dart';
import '../../../general/timeout_settings/timeout_settings_section.dart';

const String _loginMutation = r'''
mutation Login($input: LoginInput!) {
  login(input: $input) {
    clientMutationId
    accessToken
    refreshToken
  }
}
''';

final _formKey = GlobalKey<FormState>();

class UiLoginPopup extends HookConsumerWidget {
  const UiLoginPopup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final username = useTextEditingController();
    final password = useTextEditingController();
    final isLoading = useState(false);
    final errorMessage = useState<String?>(null);

    return AlertDialog(
      title: Text(context.l10n.authTypeUiLogin),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (errorMessage.value != null) ...[
              Text(
                errorMessage.value!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const Gap(8),
            ],
            TextFormField(
              controller: username,
              enabled: !isLoading.value,
              validator: (value) =>
                  value.isBlank ? context.l10n.errorUserName : null,
              decoration: InputDecoration(
                hintText: context.l10n.userName,
                border: const OutlineInputBorder(),
              ),
            ),
            const Gap(4),
            TextFormField(
              controller: password,
              enabled: !isLoading.value,
              validator: (value) =>
                  value.isBlank ? context.l10n.errorPassword : null,
              obscureText: true,
              decoration: InputDecoration(
                hintText: context.l10n.password,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        const PopButton(),
        ElevatedButton(
          onPressed: isLoading.value
              ? null
              : () async {
                  if (!(_formKey.currentState?.validate() ?? false)) return;

                  isLoading.value = true;
                  errorMessage.value = null;

                  try {
                    // Build a temporary unauthenticated client for login
                    final timeoutMs =
                        ref.read(serverRequestTimeoutProvider) ??
                            DBKeys.serverRequestTimeout.initial as int;

                    final httpLink = HttpLink(
                      Endpoints.baseApi(
                        baseUrl: ref.read(serverUrlProvider) ??
                            DBKeys.serverUrl.initial,
                        port: ref.read(serverPortProvider),
                        addPort:
                            ref.read(serverPortToggleProvider).ifNull(),
                        isGraphQl: true,
                      ),
                      defaultHeaders: {
                        'Content-Type': 'application/json; charset=utf-8'
                      },
                      httpClient: TimeoutHttpClient(
                        Duration(milliseconds: timeoutMs),
                      ),
                    );

                    final client = GraphQLClient(
                      link: httpLink,
                      cache: GraphQLCache(),
                    );

                    final result = await client.mutate(
                      MutationOptions(
                        document: gql(_loginMutation),
                        variables: {
                          'input': {
                            'username': username.text,
                            'password': password.text,
                          },
                        },
                      ),
                    );

                    if (result.hasException) {
                      final errors = result.exception?.graphqlErrors;
                      if (errors != null && errors.isNotEmpty) {
                        errorMessage.value = errors.first.message;
                      } else {
                        errorMessage.value =
                            result.exception?.linkException?.toString() ??
                                context.l10n.errorSomethingWentWrong;
                      }
                    } else {
                      final loginData = result.data?['login'];
                      if (loginData != null) {
                        final accessToken = loginData['accessToken'] as String;
                        final refreshToken =
                            loginData['refreshToken'] as String;

                        ref
                            .read(uiLoginAccessTokenProvider.notifier)
                            .update(accessToken);
                        ref
                            .read(uiLoginRefreshTokenProvider.notifier)
                            .update(refreshToken);

                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      }
                    }
                  } catch (e) {
                    errorMessage.value = e.toString();
                  } finally {
                    isLoading.value = false;
                  }
                },
          child: isLoading.value
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(context.l10n.authTypeUiLogin),
        ),
      ],
    );
  }
}
