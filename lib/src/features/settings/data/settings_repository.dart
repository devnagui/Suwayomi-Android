import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../global_providers/global_providers.dart';
import '../../../utils/extensions/custom_extensions.dart';
import '../domain/settings/settings.dart';
import './graphql/__generated__/query.graphql.dart';

part 'settings_repository.g.dart';

class SettingsRepository {
  const SettingsRepository(this.ferryClient);

  final GraphQLClient ferryClient;

  Future<SettingsDto?> getServerSettings() => ferryClient
      .query$ServerSettings(Options$Query$ServerSettings())
      .getData((data) => data.settings);

  Future<UserSettingsDto?> getUserSettings() => ferryClient
      .query$UserSettings(Options$Query$UserSettings())
      .getData((data) => data.userSettings);

  Future<List<String>?> getExtensionStores() => ferryClient
      .query$ExtensionStores(Options$Query$ExtensionStores())
      .getData((data) =>
          data.extensionStores.nodes.map((store) => store.indexUrl).toList());
}

@riverpod
SettingsRepository settingsRepository(Ref ref) =>
    SettingsRepository(ref.watch(graphQlClientProvider));
