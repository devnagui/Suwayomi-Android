// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../constants/db_keys.dart';
import '../../utils/mixin/shared_preferences_client_mixin.dart';

part 'token_manager.g.dart';

class AuthTokenRefresher {
  Future<bool>? _pending;

  Future<bool> refresh(Future<bool> Function() action) async {
    final pending = _pending;
    if (pending != null) return pending;
    final next = action();
    _pending = next;
    try {
      return await next;
    } finally {
      _pending = null;
    }
  }
}

final authTokenRefresherProvider = Provider<AuthTokenRefresher>(
  (ref) => AuthTokenRefresher(),
);

@riverpod
class UiLoginAccessToken extends _$UiLoginAccessToken
    with SharedPreferenceClientMixin<String> {
  @override
  String? build() => initialize(DBKeys.uiLoginAccessToken);
}

@riverpod
class UiLoginRefreshToken extends _$UiLoginRefreshToken
    with SharedPreferenceClientMixin<String> {
  @override
  String? build() => initialize(DBKeys.uiLoginRefreshToken);
}
