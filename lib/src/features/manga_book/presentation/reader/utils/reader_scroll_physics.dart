// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../../constants/db_keys.dart';
import '../../../../settings/presentation/reader/widgets/reader_swipe_toggle_tile/reader_swipe_chapter_toggle_tile.dart';

final readerScrollPhysicsProvider =
    Provider.autoDispose.family<ScrollPhysics?, Axis>((ref, axis) {
  final swipeEnabled =
      ref.watch(swipeChapterToggleProvider) ?? DBKeys.swipeToggle.initial;
  // Only block horizontal page drags; vertical reading and zoom stay available.
  return axis == Axis.horizontal && !swipeEnabled
      ? const NeverScrollableScrollPhysics()
      : null;
});
