// Copyright (c) 2023 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/endpoints.dart';
import '../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../network/auth_headers.dart';
import 'custom_extensions.dart';

extension CacheManagerExtension on CacheManager {
  Future<File> getServerFile(WidgetRef ref, String url,
      {bool appendApiToUrl = true}) async {
    final baseApi = "${Endpoints.baseApi(
      baseUrl: ref.read(serverUrlProvider),
      port: ref.read(serverPortProvider),
      addPort: ref.read(serverPortToggleProvider).ifNull(),
      appendApiToUrl: appendApiToUrl,
    )}"
        "$url";
    return await getSingleFile(
      baseApi,
      headers: ref.read(serverAuthHeadersProvider),
    );
  }
}
