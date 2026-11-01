// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connectivity_provider.g.dart';

/// Simple connectivity check by trying to reach the server.
/// Returns true if server is reachable.
@riverpod
class ConnectivityStatus extends _$ConnectivityStatus {
  Timer? _timer;

  @override
  bool build() {
    // Start periodic check
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    ref.onDispose(() => _timer?.cancel());

    // Initial check
    _check();
    return true; // Assume online initially
  }

  Future<void> _check() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      state = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      state = false;
    } on TimeoutException catch (_) {
      state = false;
    }
  }

  void refresh() => _check();
}
