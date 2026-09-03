// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Persistent cache manager for manga images.
/// Stores up to 2000 images with 90-day retention.
class MangaCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'sorayomiMangaCache';

  static MangaCacheManager? _instance;

  factory MangaCacheManager() {
    _instance ??= MangaCacheManager._();
    return _instance!;
  }

  MangaCacheManager._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 90),
            maxNrOfCacheObjects: 2000,
            repo: JsonCacheInfoRepository(databaseName: key),
          ),
        );
}
