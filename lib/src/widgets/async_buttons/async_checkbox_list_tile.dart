// Copyright (c) 2023 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../utils/extensions/custom_extensions.dart';
import '../custom_circular_progress_indicator.dart';

class AsyncCheckboxListTile extends HookWidget {
  const AsyncCheckboxListTile({
    super.key,
    required this.value,
    this.onChanged,
    required this.title,
  });

  final bool value;
  final Future<bool> Function(bool)? onChanged;
  final Widget title;
  @override
  Widget build(BuildContext context) {
    final localValue = useState(value);
    final isLoading = useState(false);
    useEffect(() {
      localValue.value = value;
      return null;
    }, [value]);
    return CheckboxListTile(
      value: localValue.value,
      secondary: isLoading.value ? const MiniCircularProgressIndicator() : null,
      onChanged: onChanged != null && !isLoading.value
          ? (val) async {
              final previousValue = localValue.value;
              localValue.value = val.ifNull();
              isLoading.value = true;
              try {
                final succeeded = await onChanged!(val.ifNull());
                if (!succeeded) localValue.value = previousValue;
              } catch (_) {
                localValue.value = previousValue;
                rethrow;
              } finally {
                isLoading.value = false;
              }
            }
          : null,
      title: title,
    );
  }
}
