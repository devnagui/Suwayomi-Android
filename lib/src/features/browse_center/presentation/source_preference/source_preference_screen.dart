// Copyright (c) 2023 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/misc/toast/toast.dart';
import '../../data/source_repository/source_repository.dart';
import '../source_manga_list/controller/source_manga_controller.dart';
import 'controller/source_preference_controller.dart';
import 'widgets/source_preference_to_widget.dart';

class SourcePreferenceScreen extends HookConsumerWidget {
  const SourcePreferenceScreen({super.key, required this.sourceId});

  final String sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(sourceProvider(sourceId));
    final preferenceProvider = baseSourcePreferenceListProvider(sourceId);
    final networkPreferences = ref.watch(preferenceProvider);
    final preferences = networkPreferences.valueOrNull;
    final savingPreferences = useState(<int>{});
    return Scaffold(
      appBar: AppBar(
        title: Text(
          source.valueOrNull?.displayName ?? "",
          style: context.textTheme.titleLarge,
        ),
      ),
      body: networkPreferences.showUiWhenData(
        context,
        (data) => ListView.builder(
          itemBuilder: (context, index) {
            final sourcePreference = preferences?[index];
            if (sourcePreference == null) return const SizedBox.shrink();
            return SourcePreferenceToWidget(
              key: ValueKey(
                "Source-preference-$index",
              ),
              sourcePreference: sourcePreference,
              isLoading: savingPreferences.value.contains(index),
              onChanged: (value) async {
                if (savingPreferences.value.contains(index)) return;
                savingPreferences.value = {
                  ...savingPreferences.value,
                  index,
                };
                try {
                  final result = await AsyncValue.guard(
                    () => ref
                        .read(sourceRepositoryProvider)
                        .updateSourcePreferenceById(
                          sourceId,
                          value.copyWith(position: index),
                        ),
                  );
                  if (context.mounted) {
                    result.showToastOnError(ref.read(toastProvider));
                    if (!result.hasError) ref.invalidate(preferenceProvider);
                  }
                } finally {
                  if (context.mounted) {
                    savingPreferences.value = {
                      ...savingPreferences.value,
                    }..remove(index);
                  }
                }
              },
            );
          },
          itemCount: preferences?.length ?? 0,
        ),
      ),
    );
  }
}
