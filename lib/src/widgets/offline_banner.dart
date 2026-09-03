// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../utils/network/connectivity_provider.dart';

/// Displays an offline banner at the top of the screen when server is unreachable.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOnline = ref.watch(connectivityStatusProvider);

    if (isOnline) return const SizedBox.shrink();

    return MaterialBanner(
      content: const Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline — showing cached data',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      backgroundColor: Colors.orange.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      actions: [
        TextButton(
          onPressed: () => ref.read(connectivityStatusProvider.notifier).refresh(),
          child: const Text('Retry'),
        ),
      ],
    );
  }
}
