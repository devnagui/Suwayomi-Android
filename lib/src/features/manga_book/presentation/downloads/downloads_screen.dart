// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../utils/extensions/custom_extensions.dart';
import '../../../../utils/logger/operation_log.dart';
import '../../../../utils/misc/toast/toast.dart';
import '../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../widgets/emoticons.dart';
import '../../../../widgets/popup_widgets/pop_button.dart';
import '../../data/downloads/downloads_repository.dart';
import '../../domain/downloads/downloads_model.dart';
import 'controller/downloads_controller.dart';
import 'widgets/download_progress_list_tile.dart';
import 'widgets/downloads_fab.dart';

class DownloadsScreen extends HookConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toast = ref.watch(toastProvider);
    final downloadsChapterIds = ref.watch(downloadsChapterIdsProvider);
    final downloadsGlobalStatus = ref.watch(downloaderStateProvider);
    final showDownloadsFAB = ref.watch(showDownloadsFABProvider);
    final isClearing = useState(false);

    Future<void> clearDownloads() async {
      if (isClearing.value) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.downloads),
          content: Text(context.l10n.noOfChapters(downloadsChapterIds.length)),
          actions: [
            const PopButton(),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.delete),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;

      isClearing.value = true;
      OperationLog.instance.record(
        'DownloadUiAction',
        outcome: 'triggered',
        action: 'clear_queue',
        count: downloadsChapterIds.length,
      );
      try {
        final result = await AsyncValue.guard(
          ref.read(downloadsRepositoryProvider).clearDownloads,
        );
        if (context.mounted) result.showToastOnError(toast);
        if (!result.hasError) {
          await AsyncValue.guard(
            ref.read(downloadsMapProvider.notifier).refresh,
          );
        }
      } finally {
        if (context.mounted) isClearing.value = false;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.downloads),
        actions: [
          if ((downloadsChapterIds).isNotBlank)
            IconButton(
              tooltip: context.l10n.delete,
              onPressed: isClearing.value ? null : clearDownloads,
              icon: isClearing.value
                  ? const MiniCircularProgressIndicator()
                  : const Icon(Icons.delete_sweep_rounded),
            ),
        ],
      ),
      floatingActionButton: showDownloadsFAB
          ? DownloadsFab(
              status:
                  downloadsGlobalStatus.valueOrNull ?? DownloaderState.STARTED)
          : null,
      body: downloadsGlobalStatus.showUiWhenData(
        context,
        (data) {
          if (data == null) {
            return Emoticons(title: context.l10n.errorSomethingWentWrong);
          } else if (downloadsChapterIds.isBlank) {
            return Emoticons(title: context.l10n.noDownloads);
          } else {
            final downloadsCount =
                (downloadsChapterIds.length).getValueOnNullOrNegative();
            return RefreshIndicator(
              onRefresh: () => ref.refresh(downloadStatusProvider.future),
              child: ListView.builder(
                itemExtent: 104,
                itemBuilder: (context, index) {
                  if (index == downloadsCount) return const Gap(104);
                  final chapterId = downloadsChapterIds[index];
                  return DownloadProgressListTile(
                    key: ValueKey("$chapterId"),
                    index: index,
                    downloadsCount: downloadsCount,
                    chapterId: chapterId,
                    toast: toast,
                  );
                },
                itemCount: downloadsCount + 1,
              ),
            );
          }
        },
        showGenericError: true,
      ),
    );
  }
}
