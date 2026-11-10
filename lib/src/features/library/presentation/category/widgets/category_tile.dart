// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../constants/app_sizes.dart';
import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../utils/misc/toast/toast.dart';
import '../../../../../widgets/async_buttons/async_icon_button.dart';
import '../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../../widgets/popup_widgets/pop_button.dart';
import '../../../domain/category/category_model.dart';
import '../controller/edit_category_controller.dart';
import 'edit_category_dialog.dart';

class CategoryTile extends HookConsumerWidget {
  const CategoryTile({
    super.key,
    required this.category,
    required this.maxOrderIndex,
  });

  final CategoryDto category;
  final int maxOrderIndex;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = category.order.getValueOnNullOrNegative();
    final isDefault = category.isDefaultCategory;
    final isDeleting = useState(false);

    Future<void> deleteCategory() async {
      if (isDeleting.value) return;
      isDeleting.value = true;
      try {
        final result = await ref
            .read(categoryControllerProvider.notifier)
            .deleteCategory(category.id);
        if (context.mounted) {
          result.showToastOnError(ref.read(toastProvider));
        }
      } finally {
        if (context.mounted) isDeleting.value = false;
      }
    }

    return Card(
      margin: KEdgeInsets.h16v4.size,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.label_rounded),
              title: Text(category.name),
            ),
            Row(
              children: [
                AsyncIconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: order <= 1
                      ? null
                      : () async {
                          final result = await ref
                              .read(categoryControllerProvider.notifier)
                              .reorderCategory(category.id, order - 1);
                          if (context.mounted) {
                            result.showToastOnError(ref.read(toastProvider));
                          }
                        },
                  icon: const Icon(Icons.arrow_drop_up_rounded),
                  color: Colors.grey,
                ),
                AsyncIconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: order < 1 || order >= maxOrderIndex - 1
                      ? null
                      : () async {
                          final result = await ref
                              .read(categoryControllerProvider.notifier)
                              .reorderCategory(category.id, order + 1);
                          if (context.mounted) {
                            result.showToastOnError(ref.read(toastProvider));
                          }
                        },
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  color: Colors.grey,
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => showDialog(
                    context: context,
                    builder: (context) => EditCategoryDialog(
                      category: category,
                      editCategory: (updated) => ref
                          .read(categoryControllerProvider.notifier)
                          .editCategory(category.id, updated),
                    ),
                  ),
                  icon: const Icon(Icons.edit_rounded),
                  color: Colors.grey,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: !isDefault && !isDeleting.value
                      ? () => showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(context.l10n.deleteCategoryTitle),
                              content:
                                  Text(context.l10n.deleteCategoryDescription),
                              actions: [
                                const PopButton(),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    deleteCategory();
                                  },
                                  child: Text(context.l10n.delete),
                                ),
                              ],
                            ),
                          )
                      : null,
                  icon: isDeleting.value
                      ? const MiniCircularProgressIndicator()
                      : const Icon(Icons.delete_rounded),
                  color: Colors.grey,
                ),
              ],
            ),
            const Gap(8),
          ],
        ),
      ),
    );
  }
}
