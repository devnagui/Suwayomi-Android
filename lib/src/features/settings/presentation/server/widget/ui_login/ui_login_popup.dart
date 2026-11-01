// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/db_keys.dart';
import '../../../../../../constants/endpoints.dart';
import '../../../../../../global_providers/global_providers.dart';
import '../../../../../../graphql/__generated__/schema.graphql.dart';
import '../../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../../utils/logger/auth_diagnostics.dart';
import '../../../../../../utils/logger/logger_link.dart';
import '../../../../../../utils/logger/operation_log.dart';
import '../../../../../../utils/network/mutation_cache.dart';
import '../../../../../../utils/network/timeout_http_client.dart';
import '../../../../../../utils/network/token_manager.dart';
import '../../../../../../widgets/popup_widgets/pop_button.dart';
import '../../../general/cache_recovery_section.dart';
import '../../../general/timeout_settings/timeout_settings_section.dart';
import '../../data/graphql/__generated__/login.graphql.dart';
import '../client/server_port_tile/server_port_tile.dart';
import '../client/server_url_tile/server_url_tile.dart';

final uiLoginClientProvider = Provider.autoDispose<GraphQLClient>((ref) {
  final timeoutMs = ref.watch(serverRequestTimeoutProvider) ??
      DBKeys.serverRequestTimeout.initial as int;
  final httpClient = TimeoutHttpClient(Duration(milliseconds: timeoutMs));
  ref.onDispose(httpClient.close);
  return GraphQLClient(
    link: LoggerLink().concat(HttpLink(
      Endpoints.baseApi(
        baseUrl: ref.watch(serverUrlProvider) ?? DBKeys.serverUrl.initial,
        port: ref.watch(serverPortProvider),
        addPort: ref.watch(serverPortToggleProvider).ifNull(),
        isGraphQl: true,
      ),
      defaultHeaders: {'Content-Type': 'application/json; charset=utf-8'},
      httpClient: httpClient,
    )),
    cache: GraphQLCache(),
  );
});

class UiLoginPopup extends HookConsumerWidget {
  const UiLoginPopup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final username = useTextEditingController();
    final password = useTextEditingController();
    final isLoading = useState(false);
    final errorMessage = useState<String?>(null);
    final client = ref.watch(uiLoginClientProvider);
    final formKey = useMemoized(() => GlobalKey<FormState>());

    String visibleError(String message) {
      final issue = classifyAuthIssue(message);
      if (issue == AuthIssue.alreadyAuthenticated) {
        return context.l10n.uiLoginAlreadyAuthenticated;
      }
      return redactAuthError(message, [
        password.text,
        ref.read(uiLoginAccessTokenProvider),
        ref.read(uiLoginRefreshTokenProvider),
      ]);
    }

    return AlertDialog(
      title: Text(context.l10n.authTypeUiLogin),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (errorMessage.value != null) ...[
                SelectableText(
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
      ),
      actions: [
        const OperationLogTile(compact: true),
        if (errorMessage.value != null)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: errorMessage.value!));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.copied)),
              );
            },
            child: Text(context.l10n.copyError),
          ),
        const PopButton(),
        ElevatedButton(
          onPressed: isLoading.value
              ? null
              : () async {
                  if (!(formKey.currentState?.validate() ?? false)) return;

                  isLoading.value = true;
                  errorMessage.value = null;

                  try {
                    final result = await client.mutate$Login(
                      Options$Mutation$Login(
                        operationName: 'Login',
                        variables: Variables$Mutation$Login(
                          input: Input$LoginInput(
                            username: username.text,
                            password: password.text,
                          ),
                        ),
                      ),
                    );
                    if (!context.mounted) return;

                    if (result.hasException) {
                      final errors = result.exception?.graphqlErrors;
                      if (errors != null && errors.isNotEmpty) {
                        errorMessage.value = visibleError(errors.first.message);
                      } else {
                        final failure = result.exception?.linkException;
                        if (failure is HttpLinkServerException) {
                          errorMessage.value =
                              failure.response.statusCode == 401
                                  ? context.l10n.uiLoginHttpUnauthorized
                                  : context.l10n.uiLoginHttpFailure(
                                      failure.response.statusCode);
                          OperationLog.instance.record('Login',
                              outcome: 'http_error',
                              httpStatus: failure.response.statusCode);
                        } else {
                          errorMessage.value = visibleError(
                              failure?.toString() ??
                                  context.l10n.errorSomethingWentWrong);
                        }
                      }
                    } else {
                      final loginData = result.parsedData?.login;
                      if (loginData != null) {
                        final accessToken = loginData.accessToken;
                        final refreshToken = loginData.refreshToken;
                        if (accessToken.trim().isEmpty ||
                            refreshToken.trim().isEmpty) {
                          throw StateError('Login returned empty tokens');
                        }
                        await ref.read(hiveStoreProvider).reset();
                        await MutationCache().clear();
                        if (!context.mounted) return;

                        ref
                            .read(uiLoginAccessTokenProvider.notifier)
                            .update(accessToken);
                        ref
                            .read(uiLoginRefreshTokenProvider.notifier)
                            .update(refreshToken);
                        ref.invalidate(graphQlClientProvider);

                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      } else {
                        errorMessage.value =
                            context.l10n.errorSomethingWentWrong;
                      }
                    }
                  } catch (e) {
                    OperationLog.instance.record('Login',
                        outcome: 'failed', errorType: e.runtimeType.toString());
                    if (context.mounted) {
                      errorMessage.value = visibleError(e.toString());
                    }
                  } finally {
                    if (context.mounted) isLoading.value = false;
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
