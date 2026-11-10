// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../constants/app_sizes.dart';
import '../../../routes/router_config.dart';
import '../../../utils/extensions/custom_extensions.dart';
import '../../../utils/misc/toast/toast.dart';
import '../../../widgets/custom_circular_progress_indicator.dart';
import '../../library/domain/category/category_model.dart';
import '../data/updates/updates_repository.dart';
import '../domain/update_status/update_status_model.dart';

final updateRequestInFlightProvider = StateProvider<bool>((ref) => false);
int _updateRequestSerial = 0;

Future<void> requestLibraryUpdate(
  WidgetRef ref, {
  int? categoryId,
}) async {
  if (ref.read(updateRequestInFlightProvider)) return;
  final requestState = ref.read(updateRequestInFlightProvider.notifier);
  final repository = ref.read(updatesRepositoryProvider);
  final toast = ref.read(toastProvider);
  final requestSerial = ++_updateRequestSerial;
  requestState.state = true;
  final result = await AsyncValue.guard(
    () => repository.fetchUpdates(categoryId: categoryId),
  );
  result.showToastOnError(toast);
  if (result.hasError) {
    if (_updateRequestSerial == requestSerial) requestState.state = false;
    return;
  }
  Future<void>.delayed(const Duration(seconds: 10), () {
    if (_updateRequestSerial == requestSerial) requestState.state = false;
  });
}

class UpdateStatusPopupMenu extends ConsumerWidget {
  const UpdateStatusPopupMenu({
    super.key,
    this.getCategory,
    this.showSummaryButton = true,
  });
  final CategoryDto? Function()? getCategory;
  final bool showSummaryButton;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isStarting = ref.watch(updateRequestInFlightProvider);
    final updateStatus = ref.watch(updatesSocketProvider).valueOrNull;
    final isUpdating = updateStatus?.isUpdateChecking.ifNull() ?? false;
    if (isStarting && isUpdating) {
      Future.microtask(
        () => ref.read(updateRequestInFlightProvider.notifier).state = false,
      );
    }
    return PopupMenuButton(
      enabled: !isStarting,
      icon: isStarting
          ? const MiniCircularProgressIndicator()
          : const Icon(Icons.more_vert_rounded),
      shape: RoundedRectangleBorder(borderRadius: KBorderRadius.r16.radius),
      itemBuilder: (context) {
        final category = getCategory?.call();
        return [
          if (category != null && category.id != 0)
            PopupMenuItem(
              enabled: !isUpdating,
              onTap: isUpdating
                  ? null
                  : () => requestLibraryUpdate(
                        ref,
                        categoryId: category.id,
                      ),
              child: Text(context.l10n.categoryUpdate),
            ),
          PopupMenuItem(
            enabled: !isUpdating,
            onTap: isUpdating ? null : () => requestLibraryUpdate(ref),
            child: Text(context.l10n.globalUpdate),
          ),
          if (showSummaryButton)
            PopupMenuItem(
              onTap: () => const UpdateStatusRoute().push(context),
              child: Text(
                context.l10n.updatesSummary,
              ),
            ),
        ];
      },
    );
  }
}
