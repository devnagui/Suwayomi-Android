// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../utils/extensions/custom_extensions.dart';
import '../../../../../utils/misc/toast/toast.dart';
import '../../../../../widgets/custom_circular_progress_indicator.dart';
import '../../../../../widgets/popup_widgets/pop_button.dart';
import '../../../domain/category/category_model.dart';

class EditCategoryDialog extends HookConsumerWidget {
  const EditCategoryDialog({
    super.key,
    this.editCategory,
    this.createCategory,
    this.category,
  }) : assert((category != null && editCategory != null) ||
            (category == null && createCategory != null));
  final CategoryDto? category;
  final Future<AsyncValue<void>> Function(CategoryUpdate)? editCategory;
  final Future<AsyncValue<void>> Function(CategoryCreate)? createCategory;

  Future<AsyncValue<void>> submitEditCategory(
    String categoryName,
    bool defaultCategory,
  ) async {
    if (category == null) {
      return createCategory!(CategoryCreate(
        name: categoryName,
        $default: defaultCategory,
      ));
    }
    return editCategory!(CategoryUpdate(
      name: categoryName,
      $default: defaultCategory,
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoryName = useTextEditingController(text: category?.name);
    final defaultCategory = useState((category?.defaultCategory).ifNull());
    final isSaving = useState(false);

    Future<void> save() async {
      if (isSaving.value) return;
      if (categoryName.text.isBlank) {
        ref.read(toastProvider)?.showError(context.l10n.emptyCategory);
        return;
      }
      isSaving.value = true;
      try {
        final result = await submitEditCategory(
          categoryName.text,
          defaultCategory.value,
        );
        if (context.mounted) {
          result.showToastOnError(ref.read(toastProvider));
          if (!result.hasError) Navigator.pop(context);
        }
      } finally {
        if (context.mounted) isSaving.value = false;
      }
    }

    return AlertDialog(
      title: Text(
        category == null ? context.l10n.addCategory : context.l10n.editCategory,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: categoryName,
            autofocus: true,
            decoration: InputDecoration(
              hintText: category == null
                  ? context.l10n.addCategory
                  : context.l10n.editCategory,
              border: const OutlineInputBorder(),
            ),
            enabled: !isSaving.value,
            onSubmitted: (categoryName.text).isNotBlank ? (_) => save() : null,
          ),
          CheckboxListTile(
            value: defaultCategory.value,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: isSaving.value
                ? null
                : (value) {
                    if (value != null) {
                      defaultCategory.value = (value);
                    }
                  },
            title: Text(context.l10n.defaultCategory),
          )
        ],
      ),
      actions: [
        const PopButton(),
        ElevatedButton(
          onPressed: isSaving.value ? null : save,
          child: isSaving.value
              ? const MiniCircularProgressIndicator()
              : Text(context.l10n.save),
        ),
      ],
    );
  }
}
