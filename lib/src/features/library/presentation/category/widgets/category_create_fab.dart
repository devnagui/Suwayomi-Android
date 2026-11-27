// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../utils/extensions/custom_extensions.dart';
import '../controller/edit_category_controller.dart';
import 'edit_category_dialog.dart';

class CategoryCreateFab extends ConsumerWidget {
  const CategoryCreateFab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FloatingActionButton.extended(
      onPressed: () {
        showDialog(
          context: context,
          builder: (context) => EditCategoryDialog(
            createCategory:
                ref.read(categoryControllerProvider.notifier).createCategory,
          ),
        );
      },
      isExtended: context.isTablet,
      label: Text(context.l10n.addCategory),
      icon: const Icon(Icons.add_rounded),
    );
  }
}
