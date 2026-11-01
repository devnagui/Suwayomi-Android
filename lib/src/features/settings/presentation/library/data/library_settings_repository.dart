import 'package:graphql/client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../../global_providers/global_providers.dart';
import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../domain/settings/settings.dart';
import './graphql/__generated__/query.graphql.dart';

part 'library_settings_repository.g.dart';

class LibrarySettingsRepository {
  const LibrarySettingsRepository(this.ferryClient);

  final GraphQLClient ferryClient;

  Future<SettingsDto?> updateGlobalUpdateInterval(double value) => ferryClient
      .mutate$UpdateGlobalUpdateInterval(
        Options$Mutation$UpdateGlobalUpdateInterval(
          variables: Variables$Mutation$UpdateGlobalUpdateInterval(
            globalUpdateInterval: value,
          ),
        ),
      )
      .getData((data) => data.setSettings.settings);

  Future<UserSettingsDto?> updateMangaMetaData(bool value) => ferryClient
      .mutate$UpdateMangaMetaData(
        Options$Mutation$UpdateMangaMetaData(
          variables:
              Variables$Mutation$UpdateMangaMetaData(updateMangas: value),
        ),
      )
      .getData((data) => data.setUserSettings.userSettings);

  Future<UserSettingsDto?> toggleExcludeCompleted(bool value) => ferryClient
      .mutate$ToggleExcludeCompleted(
        Options$Mutation$ToggleExcludeCompleted(
          variables: Variables$Mutation$ToggleExcludeCompleted(
            excludeCompleted: value,
          ),
        ),
      )
      .getData((data) => data.setUserSettings.userSettings);

  Future<UserSettingsDto?> toggleExcludeNotStarted(bool value) => ferryClient
      .mutate$ToggleExcludeNotStarted(
        Options$Mutation$ToggleExcludeNotStarted(
          variables: Variables$Mutation$ToggleExcludeNotStarted(
            excludeNotStarted: value,
          ),
        ),
      )
      .getData((data) => data.setUserSettings.userSettings);

  Future<UserSettingsDto?> toggleExcludeUnreadChapters(bool value) =>
      ferryClient
          .mutate$ToggleExcludeUnreadChapters(
            Options$Mutation$ToggleExcludeUnreadChapters(
              variables: Variables$Mutation$ToggleExcludeUnreadChapters(
                  excludeUnreadChapters: value),
            ),
          )
          .getData((data) => data.setUserSettings.userSettings);
}

@riverpod
LibrarySettingsRepository librarySettingsRepository(Ref ref) =>
    LibrarySettingsRepository(ref.watch(graphQlClientProvider));
