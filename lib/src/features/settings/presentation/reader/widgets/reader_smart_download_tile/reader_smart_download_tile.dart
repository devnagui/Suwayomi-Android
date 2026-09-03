// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../../constants/db_keys.dart';
import '../../../../../../global_providers/global_providers.dart';

/// Whether to automatically cache the next chapter on the device while the
/// user is reading the current one.
///
/// Implemented as a manual [NotifierProvider] (no code generation) so it can be
/// added without running build_runner. Persisted in [SharedPreferences] under
/// the same key naming scheme used by the generated settings tiles.
class SmartDownloadNextChapter extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(DBKeys.smartDownloadNextChapter.name) ??
        DBKeys.smartDownloadNextChapter.initial as bool;
  }

  void update(bool value) {
    ref
        .read(sharedPreferencesProvider)
        .setBool(DBKeys.smartDownloadNextChapter.name, value);
    state = value;
  }
}

final smartDownloadNextChapterProvider =
    NotifierProvider<SmartDownloadNextChapter, bool>(
  SmartDownloadNextChapter.new,
);

class ReaderSmartDownloadTile extends ConsumerWidget {
  const ReaderSmartDownloadTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SwitchListTile(
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: const Icon(Icons.download_for_offline_outlined),
      title: const Text('Smart download'),
      subtitle: const Text(
        'Automatically cache the next chapter on this device while reading',
      ),
      onChanged: ref.read(smartDownloadNextChapterProvider.notifier).update,
      value: ref.watch(smartDownloadNextChapterProvider),
    );
  }
}
