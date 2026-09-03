// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../utils/network/offline_chapter_manager.dart';

part 'offline_reader_provider.g.dart';

/// Provider that loads offline page file paths for a chapter.
/// Returns null if the chapter is not available offline.
@riverpod
Future<List<File>?> offlineChapterPages(
  Ref ref, {
  required int mangaId,
  required int chapterId,
}) {
  return ref
      .watch(offlineChapterManagerProvider)
      .getOfflinePages(mangaId, chapterId);
}
