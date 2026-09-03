// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../constants/db_keys.dart';
import '../../utils/mixin/shared_preferences_client_mixin.dart';

part 'token_manager.g.dart';

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
