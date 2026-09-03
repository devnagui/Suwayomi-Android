// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Simple file-based JSON cache for mutation results that graphql_flutter
/// doesn't cache (mutations are never written to HiveStore).
class MutationCache {
  static MutationCache? _instance;

  factory MutationCache() {
    _instance ??= MutationCache._();
    return _instance!;
  }

  MutationCache._();

  Future<Directory>? _cacheDir;

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'mutation_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _sanitizeKey(String key) =>
      key.replaceAll(RegExp(r'[^\w]'), '_');

  /// Save JSON data to local cache.
  Future<void> put(String key, dynamic jsonData) async {
    try {
      _cacheDir ??= _getCacheDir();
      final dir = await _cacheDir!;
      final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
      await file.writeAsString(jsonEncode(jsonData));
    } catch (_) {
      // Best-effort caching
    }
  }

  /// Read cached JSON data. Returns null if not found.
  Future<dynamic> get(String key) async {
    try {
      _cacheDir ??= _getCacheDir();
      final dir = await _cacheDir!;
      final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
      if (await file.exists()) {
        final content = await file.readAsString();
        return jsonDecode(content);
      }
    } catch (_) {
      // Cache miss
    }
    return null;
  }

  /// Remove a cached entry.
  Future<void> remove(String key) async {
    try {
      _cacheDir ??= _getCacheDir();
      final dir = await _cacheDir!;
      final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
