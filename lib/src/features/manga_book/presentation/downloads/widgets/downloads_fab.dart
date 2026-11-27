// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../utils/logger/operation_log.dart';
import '../../../../../utils/misc/toast/toast.dart';
import '../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../data/downloads/downloads_repository.dart';
import '../../../domain/downloads/downloads_model.dart';
import '../controller/downloads_controller.dart';

class DownloadsFab extends HookConsumerWidget {
  const DownloadsFab({super.key, required this.status});
  final DownloaderState status;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toast = ref.watch(toastProvider);
    final isLoading = useState(false);

    Future<void> mutateDownloads({
      required String action,
      required Future<void> Function() mutation,
    }) async {
      if (isLoading.value) return;
      isLoading.value = true;
      OperationLog.instance.record(
        'DownloadUiAction',
        outcome: 'triggered',
        action: action,
      );
      try {
        final result = await AsyncValue.guard(mutation);
        result.showToastOnError(toast);
        if (!result.hasError) {
          await AsyncValue.guard(
            ref.read(downloadsMapProvider.notifier).refresh,
          );
        }
      } finally {
        if (context.mounted) isLoading.value = false;
      }
    }

    if (status == DownloaderState.STOPPED) {
      return FloatingActionButton.extended(
        onPressed: isLoading.value
            ? null
            : () => mutateDownloads(
                  action: 'resume_queue',
                  mutation:
                      ref.read(downloadsRepositoryProvider).startDownloads,
                ),
        label: Text(context.l10n.resume),
        isExtended: context.isTablet,
        icon: isLoading.value
            ? const MiniCircularProgressIndicator()
            : const Icon(Icons.play_arrow_rounded),
      );
    } else {
      return FloatingActionButton.extended(
        onPressed: isLoading.value
            ? null
            : () => mutateDownloads(
                  action: 'pause_queue',
                  mutation: ref.read(downloadsRepositoryProvider).stopDownloads,
                ),
        label: Text(context.l10n.pause),
        isExtended: context.isTablet,
        icon: isLoading.value
            ? const MiniCircularProgressIndicator()
            : const Icon(Icons.pause_rounded),
      );
    }
  }
}
